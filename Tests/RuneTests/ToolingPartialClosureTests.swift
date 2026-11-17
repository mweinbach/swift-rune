import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Tooling Partial Closure Tests (parser_tests + tests + trace)", .serialized)
struct ToolingPartialClosureTests {

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - tooling/parser_tests.rs

    @Test("parser_tests.rs: a_file_drop_hovers_then_drops_at_its_point")
    func fileDropHoversThenDropsAtPoint() throws {
        let json = """
        [
            {"drag_files": {"paths": ["a.png"], "key": "zone"}},
            {"t": 0.5, "drop_files": {"paths": ["a.png", "b.png"], "at": [10, 20], "hover": 0.25}},
            {"t": 1.0, "drag_files": "leave"}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        #expect(steps.count == 4)
        #expect(steps[0].t == 0.0)
        #expect(steps[0].position == .key("zone"))
        #expect(steps[0].action == .dragFiles([URL(fileURLWithPath: "a.png")]))

        #expect(steps[1].t == 0.5)
        #expect(steps[1].position == .xy(10, 20))
        #expect(steps[1].action == .dragFiles([URL(fileURLWithPath: "a.png"), URL(fileURLWithPath: "b.png")]))

        #expect(steps[2].t == 0.75)
        #expect(steps[2].position == .xy(10, 20))
        #expect(steps[2].action == .dropFiles([URL(fileURLWithPath: "a.png"), URL(fileURLWithPath: "b.png")]))

        #expect(steps[3].t == 1.0)
        #expect(steps[3].position == .relative(0, 0))
        #expect(steps[3].action == .dragFilesLeave)
    }

    @Test("parser_tests.rs: a_physical_chord_releases_its_modifiers_after_the_key")
    func physicalChordReleasesModifiersAfterKey() throws {
        let json = """
        [
            {"physical": "alt+super+space"},
            {"t": 0.1, "physical": "f5"}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        let inputs = steps.compactMap { step -> PhysicalInput? in
            if case .physical(let input) = step.action { return input }
            return nil
        }
        #expect(inputs.count == 5)
        let parsed = try ParsedShortcut.parseOn("alt+super+space", platform: .current)
        let superHeld = (parsed.mods & ParsedShortcut.superBit) != 0
        #if os(macOS)
        let ctrlExpected = (parsed.mods & ParsedShortcut.ctrlBit) != 0
        #else
        let ctrlExpected = (parsed.mods & ParsedShortcut.ctrlBit) != 0 || superHeld
        #endif
        let expectedMods = Mods(
            shift: (parsed.mods & ParsedShortcut.shiftBit) != 0,
            ctrl: ctrlExpected,
            alt: (parsed.mods & ParsedShortcut.altBit) != 0,
            cmd: superHeld,
            logo: superHeld
        )
        #expect(inputs == [
            .key(key: .space, mods: expectedMods, pressed: true, repeat: false),
            .key(key: .space, mods: expectedMods, pressed: false, repeat: false),
            .modifiers(.none),
            .key(key: .f5, mods: .none, pressed: true, repeat: false),
            .key(key: .f5, mods: .none, pressed: false, repeat: false),
        ])
    }

    @Test("parser_tests.rs: script_events_answer_a_file_dialog")
    func scriptEventsAnswerFileDialog() throws {
        let json = """
        [
            {"t": 0.1, "type": "file-dialog", "path": "/exports/a.json"},
            {"t": 0.2, "type": "file-dialog-cancel"}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        let events = HeadlessRunner.headlessEvents(from: steps)
        #expect(steps.map(\.action) == [
            .fileDialogAnswer(URL(fileURLWithPath: "/exports/a.json")),
            .fileDialogAnswer(nil),
        ])
        #expect(events.map(\.event) == [
            .fileDialog("/exports/a.json"),
            .fileDialog(nil),
        ])
    }

    @Test("parser_tests.rs: script_events_answer_a_pop_up_menu")
    func scriptEventsAnswerPopUpMenu() throws {
        let json = """
        [
            {"t": 0.2, "type": "menu-cancel"},
            {"t": 0.1, "type": "menu-pick", "id": "dark"}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        let events = HeadlessRunner.headlessEvents(from: steps)
        #expect(steps.map(\.action) == [.popupPick("dark"), .popupPick(nil)])
        #expect(events.map(\.event) == [.popupMenu("dark"), .popupMenu(nil)])
    }

    @Test("parser_tests.rs: a_script_paste_can_carry_html_rtf_and_an_image")
    func scriptPasteCarriesHtmlRtfAndImage() throws {
        let dir = try makeTempDir("rune-script-paste")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngURL = dir.appendingPathComponent("clip.png")
        try Frame(width: 1, height: 2, rgba: [UInt8](repeating: 9, count: 8)).writePNG(to: pngURL)

        let json = """
        [
            {"type": "paste", "text": "plain"},
            {"paste": "short"},
            {"paste": {"text": "Hi", "html": "<b>Hi</b><img src=x onerror=y>", "rtf": "{\\\\rtf1 Hi}"}},
            {"paste": {"png": "\(pngURL.path)"}}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        let publicEvents = HeadlessRunner.headlessEvents(from: steps).map(\.event)
        #expect(Array(publicEvents.prefix(2)) == [.paste("plain"), .paste("short")])

        let rt = Runtime<[ClipboardContent]>(
            state: [],
            viewport: Vec2(100, 100),
            view: { _, _ in
                El().onPasteContent { state, content, _ in
                    state.append(content)
                }
            }
        )
        rt.frame(at: 0.0)
        for step in steps {
            guard case .paste(let content) = step.action else {
                Issue.record("expected paste step, got \(step.action)")
                continue
            }
            rt.paste(content, at: 0.0)
        }
        rt.frame(at: 0.0)
        #expect(rt.state.count == 4)
        #expect(rt.state[0].text == "plain" && rt.state[0].html == nil && rt.state[0].rtf == nil && rt.state[0].image == nil)
        #expect(rt.state[1].text == "short" && rt.state[1].html == nil && rt.state[1].rtf == nil && rt.state[1].image == nil)
        #expect(rt.state[2].text == "Hi")
        #expect(rt.state[2].html == "<b>Hi</b><img src=x>")
        #expect(rt.state[2].rtf == "{\\rtf1 Hi}")
        #expect(rt.state[2].image == nil)
        #expect(rt.state[3].text == "")
        #expect(rt.state[3].image?.width == 1 && rt.state[3].image?.height == 2)
    }

    @Test("parser_tests.rs: a_script_key_with_a_code_reaches_handlers_with_its_physical_key")
    func scriptKeyWithCodeReachesHandlersWithPhysicalKey() throws {
        let json = """
        [
            {"type": "key", "name": "&", "cmd": true, "shift": true, "code": "7"},
            {"t": 0.1, "type": "key", "name": "&", "cmd": true, "shift": true}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        var seen: [(Key, PhysicalKeyCode?)] = []
        final class Box: @unchecked Sendable { var items: [(Key, PhysicalKeyCode?)] = [] }
        let box = Box()
        let rt = Runtime<Void>(
            state: (),
            viewport: Vec2(100, 100),
            onKey: { _, ev, tx in
                box.items.append((ev.key, tx.physicalKey()))
                return true
            },
            view: { _, _ in El() }
        )
        for step in steps {
            switch step.action {
            case .keyDown(let kev):
                rt.keyDown(kev, at: 0.0)
            case let .physicalKey(phys, kev, base):
                rt.physicalInput(phys, fallbackKey: kev, baseChar: base, at: 0.0)
            case .physical(let phys):
                rt.physicalInput(phys, at: 0.0)
            default:
                Issue.record("unexpected step \(step.action)")
            }
            rt.frame(at: 0.0)
        }
        seen = box.items
        #expect(seen.count == 2)
        #expect(seen[0].0 == .command("&") && seen[0].1 == .digit7)
        #expect(seen[1].0 == .command("&") && seen[1].1 == nil)
    }

    @Test("parser_tests.rs: a_script_key_with_a_code_reaches_handlers_with_its_unmodified_character")
    func scriptKeyWithCodeReachesHandlersWithUnmodifiedCharacter() throws {
        let json = """
        [
            {"type": "key", "name": "å", "alt": true, "code": "a", "base": "a"},
            {"t": 0.1, "type": "key", "name": "k", "cmd": true, "code": "k"},
            {"t": 0.2, "type": "key", "name": "&", "cmd": true, "shift": true, "code": "7"},
            {"t": 0.3, "type": "key", "name": "k", "cmd": true},
            {"t": 0.4, "type": "key-up", "name": "q", "code": "a"}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        final class Box: @unchecked Sendable { var items: [(Key, Character?)] = [] }
        let box = Box()
        let rt = Runtime<Void>(
            state: (),
            viewport: Vec2(100, 100),
            onKey: { _, ev, tx in
                box.items.append((ev.key, tx.keyBase()))
                return true
            },
            view: { _, _ in
                El().onKeyUp { _, ev, tx in
                    box.items.append((ev.key, tx.keyBase()))
                    return true
                }
            }
        )
        for step in steps {
            switch step.action {
            case .keyDown(let kev):
                rt.keyDown(kev, at: 0.0)
            case let .physicalKey(phys, kev, base):
                rt.physicalInput(phys, fallbackKey: kev, baseChar: base, at: 0.0)
            case .physical(let phys):
                rt.physicalInput(phys, at: 0.0)
            default:
                Issue.record("unexpected step \(step.action)")
            }
            rt.frame(at: 0.0)
        }
        #expect(box.items.count == 5)
        #expect(box.items[0].0 == .text("å") && box.items[0].1 == Character("a"))
        #expect(box.items[1].0 == .command("k") && box.items[1].1 == Character("k"))
        #expect(box.items[2].0 == .command("&") && box.items[2].1 == nil)
        #expect(box.items[3].0 == .command("k") && box.items[3].1 == nil)
        #expect(box.items[4].0 == .text("q") && box.items[4].1 == Character("q"))
    }

    @Test("parser_tests.rs: a_script_key_can_be_a_held_keys_repeat")
    func scriptKeyCanBeHeldKeysRepeat() throws {
        let json = """
        [
            {"type": "key", "name": "Enter"},
            {"t": 0.1, "type": "key", "name": "Enter", "repeat": true},
            {"t": 0.2, "physical": "f5", "repeat": true}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        let rt = Runtime<[Bool]>(
            state: [],
            viewport: Vec2(100, 100),
            onKey: { state, _, tx in
                state.append(tx.keyRepeat())
                return true
            },
            view: { _, _ in El() }
        )
        var physicalFlags: [(Bool, Bool)] = []
        for step in steps {
            switch step.action {
            case .keyDown(let kev):
                rt.keyDown(kev, isRepeat: false, at: 0.0)
            case .keyRepeat(let kev):
                rt.keyDown(kev, isRepeat: true, at: 0.0)
            case .physical(.key(_, _, let pressed, let rep)):
                physicalFlags.append((pressed, rep))
            default:
                Issue.record("unexpected step \(step.action)")
            }
        }
        rt.frame(at: 0.0)
        #expect(rt.state == [false, true])
        #expect(physicalFlags.count == 2)
        #expect(physicalFlags[0] == (true, true))
        #expect(physicalFlags[1] == (false, false))
    }

    @Test("parser_tests.rs: window_panel_headless_focus_steps_preserve_false_and_event_order")
    func windowPanelFocusStepsPreserveFalseAndOrder() throws {
        let json = """
        [
            {"focus": true},
            {"t": 0.1, "focus": false},
            {"t": 0.2, "focus": false}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        #expect(steps.count == 3)
        let rt = Runtime<[Bool]>(state: [], viewport: Vec2(100, 100), view: { _, _ in El() })
        rt.windowFocused = false
        rt.onFocus = { state, focused, _ in state.append(focused) }
        for step in steps {
            guard case .windowFocus(let focused) = step.action else {
                Issue.record("expected windowFocus step")
                continue
            }
            rt.dispatchFocus(focused)
        }
        #expect(rt.state == [true, false])
    }

    @Test("parser_tests.rs: scripts_drive_wheels_pinches_other_buttons_and_key_releases")
    func scriptsDriveWheelsPinchesButtonsAndKeyReleases() throws {
        let json = """
        [
            {"type": "wheel", "x": 10, "y": 20, "dx": -4, "dy": 6, "cmd": true, "phase": "began"},
            {"t": 0.1, "type": "magnify", "delta": 0.2},
            {"t": 0.2, "type": "drag", "button": "middle", "key": "canvas", "dx": 30, "dur": 0.01},
            {"t": 0.3, "type": "key-up", "name": " "}
        ]
        """
        let steps = try HeadlessRunner.parseScript(jsonData: Data(json.utf8))
        #expect(steps[0].action == .move)
        #expect(steps[0].position == .xy(10, 20))
        guard case .wheel(let w) = steps[1].action else {
            Issue.record("expected wheel step at index 1")
            return
        }
        #expect(w.dx == -4 && w.dy == 6 && w.mods.cmd && w.phase == .began && w.precise)
        guard case .magnify(let m) = steps[2].action else {
            Issue.record("expected magnify step at index 2")
            return
        }
        #expect(abs(m.delta - 0.2) < 1e-6 && steps[2].position == .relative(0, 0))
        #expect(steps[4].action == .down(.middle, .none))
        #expect(steps.contains(where: { $0.action == .up(.middle, .none) }))
        #expect(steps.last?.action == .keyUp(KeyEvent(key: .space, mods: .none))
            || steps.last?.action == .keyUp(KeyEvent(key: .text(" "), mods: .none)))
        let pub = HeadlessRunner.headlessEvents(from: steps)
        #expect(pub.last?.event == .keyUp(KeyEvent(key: .space, mods: .none))
            || pub.last?.event == .keyUp(KeyEvent(key: .text(" "), mods: .none)))
        #expect(pub[1].event == .wheel(dx: -4, dy: 6, mods: w.mods))
    }

    // MARK: - tooling/tests.rs & tooling/trace.rs

    @Test("tests.rs:5 - trace_annotations_from_hidden_poll_survive_idle_catch_up_once")
    func traceAnnotationsFromHiddenPollSurviveOnce() throws {
        let buffer = SharedBuffer()
        let trace = MotionTrace.inMemory(
            header: TraceHeader(launch: "hidden", width: 100, height: 100, hz: 60, scale: 1),
            buffer: buffer
        )
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(100, 100),
            view: { _, _ in El() }
        )
        rt.setTrace(trace)
        rt.traceChannels = [:]
        rt.poll = { pending, _, tx in
            guard pending else { return false }
            pending = false
            tx.traceEvent("hidden:ready")
            tx.traceChannel("shell.width", kind: .position, value: 40.0)
            return true
        }
        rt.frame(at: 0.0)
        rt.state = true
        let commitsBefore = rt.viewCommitCount
        _ = rt.runPoll(at: 0.01)
        #expect(rt.viewCommitCount == commitsBefore)
        rt.frame(at: 0.02)
        rt.frame(at: 0.04)
        #expect(rt.traceEvents == ["hidden:ready"])
        #expect(rt.traceChannels?["shell.width"]?.kind == .position)
        #expect(rt.traceChannels?["shell.width"]?.value == 40.0)
        rt.takeTrace()?.flush()
        let lines = buffer.contents()
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let readyLines = lines.filter { ($0["ev"] as? [String]) == ["hidden:ready"] }
        #expect(readyLines.count == 1)
    }

    @Test("tests.rs:33 - trace_annotations_reach_both_writers_once")
    func traceAnnotationsReachBothWritersOnce() throws {
        let dir = try makeTempDir("rune-annotations")
        defer { try? FileManager.default.removeItem(at: dir) }
        let traceURL = dir.appendingPathComponent("trace.jsonl")

        let buffer = SharedBuffer()
        let motionTrace = MotionTrace.inMemory(
            header: TraceHeader(launch: "pill", width: 100, height: 100, hz: 60, scale: 1),
            buffer: buffer
        )
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { changed, _ in
                let (cls, host) = changed ? ("other", "other-host") : ("gpui", "pill")
                return El().key("root").traceNamespace(cls, host)
                    .child(El().key("generation-7").traceName("chip:Area").size(30, 20))
                    .child(El().key("fixed").traceName("fixed").traceNamespace("gpui", "pill"))
            }
        )
        rt.setTrace(motionTrace)
        rt.traceChannels = [:]

        let writer = ToolingTraceWriter(path: traceURL.path, viewport: rt.viewport, fps: 60.0, scale: 1.0, traceAll: false)
        rt.update(at: 0.0) { _, tx in
            #expect(tx.tracing)
            tx.traceEvent("lab:Start")
            tx.traceChannel("shell.width", kind: .position, value: 30.0)
        }
        rt.update(at: 0.0) { _, tx in
            tx.traceEvent("lab:Ready")
            tx.traceChannel("shell.width", kind: .position, value: 40.0)
        }
        rt.frame(at: 0.0)
        writer.recordFrame(runtime: rt, tMs: 0.0, cpuMs: 0.0)
        rt.frame(at: 0.02)
        writer.recordFrame(runtime: rt, tMs: 20.0, cpuMs: 0.0)
        rt.update(at: 0.02) { s, _ in s = true }
        rt.frame(at: 0.02)
        writer.recordFrame(runtime: rt, tMs: 40.0, cpuMs: 0.0)
        try writer.finish()
        rt.takeTrace()?.flush()

        let toolingText = try String(contentsOf: traceURL, encoding: .utf8)
        for text in [toolingText, buffer.contents()] {
            let lines = text
                .split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            #expect(lines.count >= 4)
            let metas1 = (lines[1]["m"] as? [[String: Any]]) ?? []
            let chip = try #require(metas1.first { ($0["nm"] as? String) == "chip:Area" })
            #expect(chip["cls"] as? String == "gpui")
            #expect(chip["host"] as? String == "pill")
            #expect(lines[1]["ev"] as? [String] == ["lab:Start", "lab:Ready"])
            let cm1 = (lines[1]["cm"] as? [[String: Any]]) ?? []
            let widthCh = try #require(cm1.first { ($0["name"] as? String) == "shell.width" })
            #expect(widthCh["kind"] as? String == "position")
            let c1 = (lines[1]["c"] as? [[Any]]) ?? []
            #expect(c1.contains { ($0[0] as? NSNumber)?.intValue == (widthCh["id"] as? NSNumber)?.intValue && ($0[1] as? NSNumber)?.doubleValue == 40.0 })

            for field in ["cm", "c", "ev"] {
                #expect(lines[2][field] == nil)
            }

            let updated = (lines[3]["m"] as? [[String: Any]]) ?? []
            let renamed = try #require(updated.first { ($0["nm"] as? String) == "chip:Area" })
            #expect((renamed["id"] as? NSNumber)?.intValue == (chip["id"] as? NSNumber)?.intValue)
            #expect(renamed["cls"] as? String == "other")
            #expect(renamed["host"] as? String == "other-host")
            #expect(!updated.contains { ($0["nm"] as? String) == "fixed" })
        }
    }

    @Test("tests.rs:139 & 173 - marks_are_inert_events_and_mark_names_win_over_offsets")
    func marksAreInertAndOffsetsComplete() throws {
        let script = try HeadlessRunner.parseScript(jsonData: Data("""
        [
            {"t": 0.5, "type": "tap", "x": 1, "y": 1},
            {"t": 3.2, "type": "mark", "name": "end"},
            {"t": 1.0, "type": "mark", "name": "end-card"}
        ]
        """.utf8))
        let marks = script.compactMap { step -> (String, Double)? in
            if case .mark(let n) = step.action { return (n, step.t) }
            return nil
        }
        #expect(marks.count == 2)
        #expect(marks[0] == ("end-card", 1.0))
        #expect(marks[1] == ("end", 3.2))

        #expect(ToolingArgs.parseMarkTime("mark:end") == ToolingMarkOffset(name: "end", offset: 0.0))
        #expect(ToolingArgs.parseMarkTime("mark:end+0.5") == ToolingMarkOffset(name: "end", offset: 0.5))
        #expect(ToolingArgs.parseMarkTime("1.5") == nil)

        let marksDict = ["step-1": 2.0, "end-card": 4.0, "end+0.5": 6.0, "step": 8.0, "end": 10.0]
        #expect(try ToolingArgs.resolveMarkTime("step-1", marks: marksDict) == 2.0)
        #expect(try ToolingArgs.resolveMarkTime("step-1+0.25", marks: marksDict) == 2.25)
        #expect(try ToolingArgs.resolveMarkTime("step-1-0.5", marks: marksDict) == 1.5)
        #expect(try ToolingArgs.resolveMarkTime("end+0.5", marks: marksDict) == 6.0)
        #expect(try ToolingArgs.resolveMarkTime("end-card-0.25", marks: marksDict) == 3.75)

        for bad in ["end+0.5s", "end-", "end+NaN", "end+inf", "end+1e999"] {
            #expect(throws: ToolingError.self) {
                _ = try ToolingArgs.resolveMarkTime(bad, marks: marksDict)
            }
        }
        let parsedLastWins = ToolingArgs.parse(["--at", "mark:end", "--at", "1", "--start", "mark:step", "--start", "0"])
        #expect(parsedLastWins.atTime == 1.0 && parsedLastWins.startTime == 0.0)
    }

    @Test("tests.rs:201 & 841 & 849 - duration_out_script_trace_headless_unless_native")
    func durationOutScriptTraceHeadlessUnlessNative() throws {
        for flags in [
            ["--out", "frames"],
            ["--duration", "auto"],
            ["--duration", "auto", "--out", "frames"],
            ["--trace", "trace.jsonl", "--frames", "120"],
            ["--script", "s.json"],
        ] {
            #expect(ToolingArgs.parse(flags).isHeadlessRequested)
            #expect(ToolingProcessArgs.isHeadless(argv: ["app"] + flags))
            let nativeFlags = flags + ["--native"]
            #expect(!ToolingArgs.parse(nativeFlags).isHeadlessRequested)
            #expect(!ToolingProcessArgs.isHeadless(argv: ["app"] + nativeFlags))
        }
        #expect(ToolingArgs.parse(["--native", "--snap", "snap.png"]).isHeadlessRequested)
        #expect(!ToolingArgs.parse(["--theme", "light"]).isHeadlessRequested)

        let dir = try makeTempDir("rune-duration")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("script.json")
        try Data(#"[{"t": 0.1, "type": "mark", "name": "end"}]"#.utf8).write(to: scriptURL)

        let spec = AppSpec<Void>(title: "duration", size: Vec2(8, 8), state: (), view: { _, _ in El() })
        for automatic in [false, true] {
            let outDir = dir.appendingPathComponent(automatic ? "explicit" : "default")
            var flags = ["--script", scriptURL.path, "--out", outDir.path, "--fps", "30", "--scale", "1"]
            if automatic { flags.append(contentsOf: ["--duration", "auto"]) }
            let args = ToolingArgs.parse(flags)
            #expect(args.isHeadlessRequested)
            _ = try HeadlessRunner.run(spec, args: args)
            let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted()
            #expect(files == ["frame_0000.png", "frame_0001.png", "frame_0002.png", "frame_0003.png"])
        }
    }

    @Test("tests.rs:230 - headless_runs_report_each_frame_to_on_frame_encoded")
    func headlessRunsReportEachFrameToOnFrameEncoded() throws {
        let dir = try makeTempDir("rune-encoded")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = dir.appendingPathComponent("snap.png")

        final class Log: @unchecked Sendable { var frames: [FrameEncoded] = [] }
        let log = Log()
        let app = App(title: "encoded", size: Vec2(8, 8), state: (), view: { _, _ in El() })
            .onFrameEncoded { log.frames.append($0) }
        var args = ToolingArgs()
        args.snapPath = snap.path
        args.atTime = 0.1
        args.fps = 30.0
        args.pixelScale = 1.0
        _ = try HeadlessRunner.run(app, args: args)
        #expect(log.frames.count == 4)
        for (idx, f) in log.frames.enumerated() {
            #expect(f.seq == UInt64(idx))
            #expect(f.outcome == .drawn)
            #expect(f.window == "main")
            #expect(f.refreshHz == 30.0)
            #expect(f.updateMs >= 0)
            #expect(f.encodeMs >= 0)
        }
    }

    @Test("tests.rs:249 & 278 & 310 - snapshot_transparency_and_viewport_resizes")
    func snapshotTransparencyAndResizes() throws {
        let dir = try makeTempDir("rune-resize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("script.json")
        try Data("""
        [
            {"t": 0.05, "type": "resize", "w": 60, "h": 40},
            {"t": 0.10, "type": "resize_delta", "dw": 20, "dh": 10}
        ]
        """.utf8).write(to: script)

        let spec = AppSpec<Void>(
            title: "resize",
            size: Vec2(40, 30),
            state: (),
            view: { _, _ in El().key("box").wFull().hFull().bg(Color.srgb(0.2, 0.4, 0.8, 1.0)) }
        )
        var args = ToolingArgs.parse(["--script", script.path, "--at", "0.15", "--scale", "2", "--snap", dir.appendingPathComponent("s.png").path, "--tree", dir.appendingPathComponent("t.json").path])
        args.fps = 60.0
        let output = try HeadlessRunner.run(spec, args: args)
        #expect(output.finalFrame.width == 160 && output.finalFrame.height == 100)
        let tree = try JSONSerialization.jsonObject(with: output.treeJSON) as? [String: Any]
        #expect(tree?["viewport"] as? [Double] == [80.0, 50.0])
    }

    @Test("tests.rs:358 & 380 - snapshots_leave_playground_out_and_init_reads_headless_run")
    func snapshotsPlaygroundAndInitReadsHeadlessRun() throws {
        defer { HeadlessRun.clearCurrent() }
        let dir = try makeTempDir("rune-headless-run")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("script.json")
        try Data(#"[{"t": 0.5, "type": "tap", "x": 4, "y": 5}, {"t": 0.25, "type": "type", "text": "hi", "every": 0.1}]"#.utf8).write(to: script)

        var seenCount = 0
        var seenEnd = 0.0
        var seenSize: Vec2 = .zero
        let spec = AppSpec<Int>(
            title: "run-read",
            size: Vec2(120, 80),
            state: {
                if let run = HeadlessRun.current {
                    seenCount = run.events.count
                    seenEnd = run.scriptEnd()
                    seenSize = run.size
                }
                return seenCount
            }(),
            view: { _, _ in El().wFull().hFull() }
        )
        let args = ToolingArgs.parse(["--script", script.path, "--at", "0.6", "--scale", "1"])
        _ = try HeadlessRunner.run(spec, args: args)
        #expect(seenCount > 0)
        #expect(abs(seenEnd - 0.58) < 1e-6)
        #expect(seenSize == Vec2(120, 80))

        // Default vs --playground: playground flag toggles args.hasPlayground without mutating headless defaults
        #expect(!ToolingArgs.parse(["--snap", "a.png"]).hasPlayground)
        #expect(ToolingArgs.parse(["--snap", "a.png", "--playground"]).hasPlayground)
    }

    @Test("tests.rs:771 - size_and_scale_must_be_positive")
    func sizeAndScaleMustBePositive() throws {
        let ok = try ToolingArgs.parseChecked(["--size", "400x300.5", "--scale", "1.5"])
        #expect(ok.viewportOverride == Vec2(400, 300.5))
        #expect(ok.pixelScale == 1.5)

        for badSize in ["0x0", "400x0", "-1x10", "NaNx10", "infx10", "400", "ax3"] {
            #expect(throws: ToolingError.self) {
                _ = try ToolingArgs.parseChecked(["--size", badSize])
            }
        }
        for badScale in ["0", "-2", "NaN", "inf", "x"] {
            #expect(throws: ToolingError.self) {
                _ = try ToolingArgs.parseChecked(["--scale", badScale])
            }
        }
    }

    @Test("tests.rs:779 - keycaps_draw_over_frames_but_never_enter_the_tree")
    func keycapsDrawOverFramesButNeverEnterTree() throws {
        let dir = try makeTempDir("rune-keys")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("script.json")
        try Data(#"[{"t": 0.1, "type": "type", "text": "hi"}, {"t": 0.3, "type": "tap", "x": 150, "y": 30}]"#.utf8).write(to: script)

        func runCase(_ name: String, extra: [String]) throws -> (Data, String) {
            let snap = dir.appendingPathComponent("\(name).png")
            let tree = dir.appendingPathComponent("\(name).json")
            let spec = AppSpec<Void>(
                title: "keys",
                size: Vec2(200, 120),
                state: (),
                view: { _, _ in El().key("root").wFull().hFull().bg(.oklch(0.9, 0.0, 0.0)) }
            )
            let argv = ["--script", script.path, "--scale", "1", "--at", "0.5", "--snap", snap.path, "--tree", tree.path] + extra
            _ = try HeadlessRunner.run(spec, args: ToolingArgs.parse(argv))
            return (try Data(contentsOf: snap), try String(contentsOf: tree, encoding: .utf8))
        }

        let plain = try runCase("plain", extra: [])
        let keys = try runCase("keys", extra: ["--keys", "top-left", "--pointer"])
        let light = try runCase("light", extra: ["--keys", "top-left", "--pointer", "--keys-theme", "light"])
        let dark = try runCase("dark", extra: ["--keys", "top-left", "--pointer", "--keys-theme", "dark"])

        #expect(plain.1 == keys.1)
        #expect(plain.0 != keys.0)
        #expect(keys.0 == light.0)
        #expect(light.0 != dark.0)

        #expect(ToolingArgs.parse(["--keys", "--snap", "a.png"]).keysCorner == .bottomLeft)
        #expect(ToolingArgs.parse(["--keys", "top"]).keysCorner == .top)
        #expect(ToolingArgs.parse(["--snap", "a.png"]).keysCorner == nil)
    }

    @Test("tests.rs:812 - script_chords_only_fire_global_handlers_even_when_the_window_is_key")
    func scriptChordsOnlyFireGlobalHandlers() throws {
        let script = try HeadlessRunner.parseScript(jsonData: Data("""
        [{"t": 0.1, "type": "shortcut", "chord": "cmd+space"}, {"t": 0.2, "shortcut": "cmd+k"}]
        """.utf8))
        #expect(script.map(\.action) == [
            .shortcut(try #require(Chord(parsing: "cmd+space"))),
            .shortcut(try #require(Chord(parsing: "cmd+k"))),
        ])

        let dir = try makeTempDir("rune-chords")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("script.json")
        try Data("""
        [
            {"focus": true},
            {"t": 0.1, "type": "shortcut", "chord": "cmd+k"},
            {"t": 0.2, "type": "shortcut", "chord": "cmd+space"},
            {"t": 0.3, "shortcut": "cmd+k"},
            {"t": 0.4, "focus": false},
            {"t": 0.5, "type": "shortcut", "chord": "cmd+space"},
            {"t": 0.6, "type": "key", "name": "Escape"}
        ]
        """.utf8).write(to: path)

        final class SeenBox: @unchecked Sendable { var log: [String] = [] }
        let seen = SeenBox()
        let registry = ShortcutRegistry()
        _ = registry.register(id: "k", accelerator: "cmd+k") {
            seen.log.append("global cmd+k")
        }
        _ = registry.register(id: "space", accelerator: "cmd+space") {
            seen.log.append("global cmd+space")
        }
        let spec = AppSpec<Void>(
            title: "chords",
            size: Vec2(40, 30),
            state: (),
            onKey: { _, ev, _ in
                seen.log.append("on_key \(ev.key)")
                return true
            },
            view: { _, _ in El() }
        )
        let args = ToolingArgs.parse(["--script", path.path, "--tree", dir.appendingPathComponent("tree.json").path])
        _ = try HeadlessRunner.run(spec, args: args, shortcutRegistry: registry)
        #expect(seen.log == ["global cmd+k", "global cmd+space", "global cmd+k", "global cmd+space", "on_key escape"])
    }

    @Test("tests.rs:858 - tree_and_trace_serialize_effects_and_remove_channels")
    func treeAndTraceSerializeEffectsAndRemoveChannels() throws {
        let dir = try makeTempDir("rune-effects")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracePath = dir.appendingPathComponent("effects.jsonl")

        let liveScale = Live<Float>(0.8)
        let rt = Runtime<Bool>(
            state: true,
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { show, _ in
                var root = El<Bool>().key("root").size(100, 100)
                if show {
                    root = root.child(
                        El().key("pill")
                            .size(40, 40)
                            .opacity(0.5)
                            .liveScale(liveScale.binding)
                            .transition(.blur(sigma: 4.0))
                    )
                }
                return root
            }
        )
        rt.frame(at: 0.0)
        let tree0 = rt.treeJSON()
        let elements0 = (tree0["elements"] as? [[String: Any]]) ?? []
        let pill0 = try #require(elements0.first { ($0["key"] as? String) == "pill" })
        #expect((pill0["opacity"] as? NSNumber)?.doubleValue == 0.5)
        #expect(abs(((pill0["scale"] as? NSNumber)?.doubleValue ?? 0) - 0.8) < 1e-5)
        #expect((pill0["blur"] as? NSNumber)?.doubleValue == 0.0)

        let writer = ToolingTraceWriter(path: tracePath.path, viewport: rt.viewport, fps: 60.0, scale: 1.0, traceAll: false)
        writer.recordFrame(runtime: rt, tMs: 0.0, cpuMs: 0.0)

        rt.state = false
        rt.invalidate()
        rt.frame(at: 0.0)
        rt.frame(at: 0.05)

        let tree1 = rt.treeJSON()
        let elements1 = (tree1["elements"] as? [[String: Any]]) ?? []
        let pill1 = try #require(elements1.first { ($0["key"] as? String) == "pill" })
        #expect(pill1["exiting"] as? Bool == true)
        #expect(elements1.filter { ($0["key"] as? String) != "pill" }.allSatisfy { $0["exiting"] == nil })

        writer.recordFrame(runtime: rt, tMs: 50.0, cpuMs: 0.0)
        rt.frame(at: 3.0)
        writer.recordFrame(runtime: rt, tMs: 3050.0, cpuMs: 0.0)
        try writer.finish()

        let text = try String(contentsOf: tracePath, encoding: .utf8)
        let lines = text
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let cm1 = (lines[1]["cm"] as? [[String: Any]]) ?? []
        let blurMeta = try #require(cm1.first { ($0["name"] as? String)?.hasSuffix("pill.blur") == true })
        let blurId = try #require((blurMeta["id"] as? NSNumber)?.intValue)
        let c2 = (lines[2]["c"] as? [[Any]]) ?? []
        #expect(c2.contains { ($0[0] as? NSNumber)?.intValue == blurId && (($0[1] as? NSNumber)?.doubleValue ?? 0) > 0.0 })
        let cg3 = (lines[3]["cg"] as? [NSNumber])?.map(\.intValue) ?? []
        #expect(cg3.contains(blurId))
        let row0 = ((lines[1]["e"] as? [[Any]]) ?? []).first
        #expect(row0?.count == 8)
    }

    @Test("tests.rs:897 - trace_all_names_unkeyed_elements_and_reports_what_animated")
    func traceAllNamesUnkeyedAndReportsWhy() throws {
        #expect(ToolingArgs.parse(["--trace-all"]).traceAll)
        let dir = try makeTempDir("rune-trace-all")
        defer { try? FileManager.default.removeItem(at: dir) }

        func capture(all: Bool) throws -> [[String: Any]] {
            let path = dir.appendingPathComponent("trace-\(all).jsonl")
            let rt = Runtime<Bool>(
                state: false,
                viewport: Vec2(100, 100),
                pixelScale: 1.0,
                systemDark: true,
                view: { wide, _ in
                    El().key("root").size(100, 100)
                        .child(El().size(wide ? 80 : 20, 20).animateLayout())
                }
            )
            rt.frame(at: 0.0)
            let writer = ToolingTraceWriter(path: path.path, viewport: rt.viewport, fps: 60.0, scale: 1.0, traceAll: all)
            writer.recordFrame(runtime: rt, tMs: 0.0, cpuMs: 0.0)
            rt.state = true
            rt.invalidate()
            rt.frame(at: 0.0)
            rt.frame(at: 0.05)
            writer.recordFrame(runtime: rt, tMs: 50.0, cpuMs: 0.0)
            try writer.finish()
            let text = try String(contentsOf: path, encoding: .utf8)
            return text
                .split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        let keyedLines = try capture(all: false)
        #expect(((keyedLines[1]["m"] as? [[String: Any]]) ?? []).count == 1)

        let allLines = try capture(all: true)
        let metas = (allLines[1]["m"] as? [[String: Any]]) ?? []
        let root = try #require(metas.first { ($0["nm"] as? String) == "/@root" })
        let child = try #require(metas.first { ($0["nm"] as? String) != "/@root" })
        #expect((child["pv"] as? NSNumber)?.intValue == (root["id"] as? NSNumber)?.intValue)
        let quality = allLines[2]["quality"] as? [String: Any]
        #expect(quality?["why"] as? [String] == ["tracks"])
        let tk = (allLines[2]["tk"] as? [[Any]]) ?? []
        let childId = (child["id"] as? NSNumber)?.intValue
        #expect(tk.contains {
            ($0[0] as? NSNumber)?.intValue == childId
                && ($0[1] as? String) == "frame"
                && ($0[2] as? NSNumber)?.intValue == 1
        })
    }

    @Test("tests.rs:931 - the_window_title_starts_from_the_spec_and_follows_set_title")
    func windowTitleStartsFromSpecAndFollowsSetTitle() throws {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { _, _ in
                El().size(100, 100).onClick { n, tx in
                    n += 1
                    tx.setTitle("Notes \(n % 2)")
                }
            }
        )
        rt.windowTitle = "Notes"
        rt.frame(at: 0.0)
        #expect(rt.treeJSON()["title"] as? String == "Notes")

        rt.pointerDown(at: Vec2(50, 50), at: 0.1)
        rt.pointerUp(at: Vec2(50, 50), at: 0.1)
        rt.frame(at: 0.1)
        #expect(rt.windowTitle == "Notes 1")
        #expect(rt.treeJSON()["title"] as? String == "Notes 1")

        let changed = rt.updateIf(at: 0.2) { _, tx in
            tx.setTitle("Draft")
            return false
        }
        #expect(!changed)
        #expect(rt.windowTitle == "Draft")
    }

    @Test("tests.rs:955 - a_trace_says_how_far_scrolling_carries_an_element_when_that_changes")
    func traceRecordsElementScrollCarriageWhenChanged() throws {
        let dir = try makeTempDir("rune-trace-scrolled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("scrolled.jsonl")

        let rt = Runtime<Void>(
            state: (),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { _, _ in
                col().key("scroll").size(100, 100).scroll(stickBottom: false)
                    .child(El().key("row").wFull().h(400))
            }
        )
        rt.frame(at: 0.0)
        let writer = ToolingTraceWriter(path: path.path, viewport: rt.viewport, fps: 60.0, scale: 1.0, traceAll: false)
        writer.recordFrame(runtime: rt, tMs: 0.0, cpuMs: 0.0)
        rt.update(at: 0.02) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 30) }
        rt.frame(at: 0.02)
        writer.recordFrame(runtime: rt, tMs: 20.0, cpuMs: 0.0)
        writer.recordFrame(runtime: rt, tMs: 40.0, cpuMs: 0.0)
        try writer.finish()

        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let metas1 = (lines[1]["m"] as? [[String: Any]]) ?? []
        let rowMeta = try #require(metas1.first { ($0["nm"] as? String)?.hasSuffix("row") == true })
        let rowId = try #require((rowMeta["id"] as? NSNumber)?.intValue)
        #expect(lines[1]["sc"] == nil)
        let sc2 = (lines[2]["sc"] as? [[NSNumber]]) ?? []
        #expect(sc2.map { $0.map(\.doubleValue) } == [[Double(rowId), 0.0, 30.0]])
        #expect(lines[3]["sc"] == nil)
    }

    @Test("trace.rs: tree_json_emits_imeArea_preedit_tooltip_selection_and_accessibility")
    func treeJsonEmitsImePreeditTooltipSelectionAndAccessibility() throws {
        var edit = TextEdit("hello")
        edit.selectAll()
        let rt = Runtime<TextEdit>(
            state: edit,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { _, _ in
                textInput(key: "editor", \.self)
                    .size(160, 40)
                    .help("Type query")
            }
        )
        rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(40, 20), at: 0.05)
        rt.pointerUp(at: Vec2(40, 20), at: 0.06)
        _ = rt.dispatchImeEvent(.preedit("nihao", cursorUTF8: 2..<2, clauses: []), at: 0.07)
        rt.pointerMove(to: Vec2(40, 20), at: 0.1)
        rt.frame(at: 0.1)
        rt.frame(at: 0.8)
        let tree = rt.treeJSON()
        #expect(tree["viewport"] as? [Double] == [200.0, 100.0])
        #expect((tree["imeArea"] as? [Double])?.count == 4)
        let preedit = try #require(tree["preedit"] as? [String: Any])
        #expect(preedit["text"] as? String == "nihao")
        #expect(preedit["cursor"] as? [Int] == [2, 2])
        let elements = (tree["elements"] as? [[String: Any]]) ?? []
        let editorEl = try #require(elements.first { ($0["key"] as? String) == "editor" })
        #expect((editorEl["selection"] as? [Int])?.count == 2)
        let tip = try #require(tree["tooltip"] as? [String: Any])
        #expect(tip["text"] as? String == "Type query")
        #if os(macOS) && canImport(AppKit)
        #expect(tree["accessibility"] != nil)
        #endif
    }

    @Test("trace.rs:225 - trace writer takes and resets Scene.store retarget audit across frames")
    func traceWriterTakesAndResetsRetargetAuditAcrossFrames() throws {
        let dir = try makeTempDir("rune-retarget-reset")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("retarget.jsonl")

        let rt = Runtime<Float>(
            state: 20,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: { width, _ in
                El().key("root").size(200, 100)
                    .child(El().key("box").size(width, 20).animateLayout(.snappy))
            }
        )
        rt.traceChannels = [:]
        rt.auditRetargets(true)

        let writer = ToolingTraceWriter(path: path.path, viewport: rt.viewport, fps: 60.0, scale: 1.0, traceAll: false)
        rt.frame(at: 0.0)
        writer.recordFrame(runtime: rt, tMs: 0.0, cpuMs: 0.0)

        rt.state = 140
        rt.invalidate()
        rt.frame(at: 0.05)
        writer.recordFrame(runtime: rt, tMs: 50.0, cpuMs: 0.0)

        // Retarget mid-flight so Scene.store records spatial retarget lanes.
        rt.state = 40
        rt.invalidate()
        rt.frame(at: 0.08)
        writer.recordFrame(runtime: rt, tMs: 80.0, cpuMs: 0.0)

        // Next frame has no new retarget; trace writer must have cleared Scene.store's audit.
        rt.frame(at: 0.10)
        writer.recordFrame(runtime: rt, tMs: 100.0, cpuMs: 0.0)
        try writer.finish()

        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(lines.count == 5)
        let qRetarget = try #require(lines[3]["quality"] as? [String: Any])
        #expect(((qRetarget["retarget_lanes"] as? NSNumber)?.intValue ?? 0) > 0)
        let qNext = try #require(lines[4]["quality"] as? [String: Any])
        #expect((qNext["retarget_lanes"] as? NSNumber)?.intValue == 0)
        #expect((qNext["velocity_error_pt_s"] as? NSNumber)?.doubleValue == 0.0)
    }

    // MARK: - tooling/tests.rs (:89, :332, :458..768)

    private static let desktopLogLock = NSLock()
    private nonisolated(unsafe) static var desktopKeyed: [String] = []
    private nonisolated(unsafe) static var desktopReopened: [(String, Bool)] = []

    private struct DesktopPair: Sendable {
        let name: String
        var color: Color
        let other: AppHandle<DesktopPair>?
        let act: @Sendable (AppHandle<DesktopPair>, inout Tx) -> Void
    }

    private func writeRGBAPNG(at url: URL, width: Int, height: Int, rgba: [UInt8]) throws {
        try Frame(width: width, height: height, rgba: rgba).writePNG(to: url)
    }

    private func readRGBAPNG(at url: URL) throws -> Frame {
        try Frame.fromPNG(data: Data(contentsOf: url))
    }

    private func makeDesktopPair(
        name: String,
        color: Color,
        other: AppHandle<DesktopPair>? = nil,
        act: @escaping @Sendable (AppHandle<DesktopPair>, inout Tx) -> Void = { _, _ in },
        options: WindowOptions,
        onFocus: ((inout DesktopPair, Bool, inout Tx) -> Void)? = nil
    ) -> (AppWindowSpec<DesktopPair>, AppHandle<DesktopPair>) {
        var app = App<DesktopPair>(
            "pair",
            size: Vec2(1, 1),
            init: { DesktopPair(name: name, color: color, other: other, act: act) },
            view: { p, _ in El<DesktopPair>().wFull().hFull().bg(p.color) }
        )
        .onKey { p, _, tx in
            Self.desktopLogLock.lock()
            Self.desktopKeyed.append(p.name)
            Self.desktopLogLock.unlock()
            if let other = p.other {
                p.act(other, &tx)
            }
            return true
        }
        if let onFocus {
            app = app.onFocus(onFocus)
        }
        let handle = app.handle()
        return (AppWindowSpec<DesktopPair>.fromApp(name, app).options(options), handle)
    }

    private func makeCloser(
        name: String,
        color: Color,
        other: AppHandle<DesktopPair>? = nil,
        hook: @escaping @Sendable (inout DesktopPair, Bool, inout Tx) -> Bool,
        options: ConfiguredWindowOptions
    ) -> (AnyWindowSpec, AppHandle<DesktopPair>) {
        let app = App<DesktopPair>(
            "closer",
            size: Vec2(1, 1),
            init: { DesktopPair(name: name, color: color, other: other, act: { _, _ in }) },
            view: { p, _ in El<DesktopPair>().wFull().hFull().bg(p.color) }
        )
        .onKey { _, _, tx in
            tx.closeWindow()
            return true
        }
        .keepRunning()
        .onReopen(hook)
        let handle = app.handle()
        return (AppWindowSpec<DesktopPair>.fromApp(name, app).configuredOptions(options).boxed(), handle)
    }

    @MainActor
    private func runDesktopCase(
        name: String,
        script: String,
        at: Double,
        extra: [String] = [],
        windows: () -> [AnyWindowSpec]
    ) throws -> (width: Int, height: Int, rgba: [UInt8], run: HeadlessRun) {
        let dir = try makeTempDir("rune-desktop-\(name)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backdrop = dir.appendingPathComponent("backdrop.png")
        let grey = Array(repeating: [UInt8]([128, 128, 128, 255]), count: 240 * 160).flatMap { $0 }
        try writeRGBAPNG(at: backdrop, width: 240, height: 160, rgba: grey)
        let scriptPath = dir.appendingPathComponent("script.json")
        let snapPath = dir.appendingPathComponent("snap.png")
        try Data(script.utf8).write(to: scriptPath)

        Self.desktopLogLock.lock()
        Self.desktopKeyed.removeAll()
        Self.desktopLogLock.unlock()

        var args = [
            "--desktop", backdrop.path,
            "--script", scriptPath.path,
            "--scale", "2",
            "--fps", "10",
            "--at", String(at),
            "--snap", snapPath.path,
        ]
        args.append(contentsOf: extra)
        try runWindowsWithArgs(options: RunOptions(), arguments: args) { _ in windows() }
        let png = try readRGBAPNG(at: snapPath)
        let run = try #require(HeadlessRun.current)
        return (png.width, png.height, png.rgba, run)
    }

    @MainActor
    private func runReopenCase(
        script: String,
        accessory: Bool,
        windows: () -> [AnyWindowSpec]
    ) throws -> HeadlessRun {
        Self.desktopLogLock.lock()
        Self.desktopReopened.removeAll()
        Self.desktopLogLock.unlock()

        let dir = try makeTempDir("rune-reopen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backdrop = dir.appendingPathComponent("backdrop.png")
        let grey = Array(repeating: [UInt8]([128, 128, 128, 255]), count: 240 * 160).flatMap { $0 }
        try writeRGBAPNG(at: backdrop, width: 240, height: 160, rgba: grey)
        let scriptPath = dir.appendingPathComponent("script.json")
        let treePath = dir.appendingPathComponent("tree.json")
        try Data(script.utf8).write(to: scriptPath)
        let args = [
            "--desktop", backdrop.path,
            "--script", scriptPath.path,
            "--scale", "2",
            "--fps", "10",
            "--tree", treePath.path,
        ]
        try runWindowsWithArgs(options: RunOptions(accessory: accessory), arguments: args) { _ in windows() }
        return try #require(HeadlessRun.current)
    }

    private static func desktopLeft() -> WindowOptions {
        WindowOptions(position: (20, 20), physicalSize: (100, 60))
    }

    private static func desktopRight() -> WindowOptions {
        WindowOptions(position: (160, 40), physicalSize: (60, 60))
    }

    private static func desktopFocusOf(_ run: HeadlessRun, at t: Double, key: String) -> (Bool, Bool) {
        let f = run.windowsAt(t).first { $0.key == key }!
        return (f.visible, f.focused)
    }

    @Test("tooling/tests.rs:89 - native_traces_add_target_and_present_times_without_changing_other_fields")
    func nativeTracesAddTargetAndPresentTimesWithoutChangingOtherFields() throws {
        final class TestPresentSource: TracePresentSource, @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(seq: UInt64, atNs: UInt64?)] = []
            func push(_ item: (seq: UInt64, atNs: UInt64?)) {
                lock.lock()
                items.append(item)
                lock.unlock()
            }
            func take() -> [(seq: UInt64, atNs: UInt64?)] {
                lock.lock()
                let out = items
                items.removeAll()
                lock.unlock()
                return out
            }
        }

        let dir = try makeTempDir("rune-present")
        defer { try? FileManager.default.removeItem(at: dir) }

        func runTrace(name: String, timed: Bool) throws -> String {
            let rt = Runtime<Bool>(
                state: false,
                viewport: Vec2(100, 100),
                pixelScale: 1.0,
                systemDark: true,
                view: { _, _ in El<Bool>().key("box").size(20, 20) }
            )
            let path = dir.appendingPathComponent("\(name).jsonl")
            let startNs: UInt64 = 1_000_000_000
            let source = TestPresentSource()
            let trace = ToolingTraceWriter.openClock(
                path: path.path,
                viewport: rt.viewport,
                fps: 120.0,
                scale: 1.0,
                clock: .wall
            )
            if timed {
                trace.recordPresents(source: source, startNs: startNs)
            }
            for k in UInt64(0)..<3 {
                rt.frame(at: Double(k + 1) / 120.0)
                let timing = TraceFrameTiming(
                    targetMs: timed ? Double(k) * 8.333 : nil,
                    drawable: timed ? k + 1 : nil,
                    continuous: k > 0
                )
                trace.frameTimed(runtime: rt, tMs: Double(k) * 8.0, cpuMs: 0.0, timing: timing)
                let atNs = startNs + 20_000_000 + k * 8_333_000
                source.push((seq: k + 1, atNs: atNs))
            }
            try trace.finish()
            return try String(contentsOf: path, encoding: .utf8)
        }

        let plain = try runTrace(name: "plain", timed: false)
        let timed = try runTrace(name: "timed", timed: true)

        func strip(_ text: String) throws -> [Data] {
            try text.split(separator: "\n").map { line in
                var obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                obj.removeValue(forKey: "target_ms")
                obj.removeValue(forKey: "present_ms")
                obj.removeValue(forKey: "present_dt_ms")
                if var q = obj["quality"] as? [String: Any] {
                    q["cpu_ms"] = 0.0
                    obj["quality"] = q
                }
                return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            }
        }

        let plainStripped = try strip(plain)
        let timedStripped = try strip(timed)
        #expect(plainStripped == timedStripped)
        #expect(!plain.contains("present_ms") && !plain.contains("target_ms"))

        let frames = try timed.split(separator: "\n").dropFirst().map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(frames.count == 3)
        #expect(abs(((frames[1]["target_ms"] as? NSNumber)?.doubleValue ?? -1) - 8.333) < 0.001)
        #expect(abs(((frames[1]["present_ms"] as? NSNumber)?.doubleValue ?? -1) - 28.333) < 0.001)
        #expect(abs(((frames[1]["present_dt_ms"] as? NSNumber)?.doubleValue ?? -1) - 8.333) < 0.001)

        let summary = try #require(TracePresentSummary.ofTrace(timed))
        #expect(summary.frames == 3)
        #expect(summary.presented == 3)
        #expect(summary.bunched == 0)
        #expect(summary.missed == 0)
        #expect(TracePresentSummary.ofTrace(plain) == nil)
    }

    @Test("tooling/tests.rs:332 - fit_content_height_follows_the_content")
    func fitContentHeightFollowsTheContent() throws {
        let dir = try makeTempDir("rune-fit-content")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("script.json")
        try Data(#"[{"t": 0.1, "type": "tap", "key": "more"}]"#.utf8).write(to: scriptURL)

        func runViewport(name: String, at: String) throws -> (Float, Float) {
            let app = App<Int>(
                "fit",
                size: Vec2(300, 400),
                init: { 1 },
                view: { rows, _ in
                    var children: [El<Int>] = [
                        El<Int>().key("more").size(50, 50).onClick { r, _ in r += 1 }
                    ]
                    for i in 0..<rows {
                        children.append(El<Int>().key("row\(i)").size(100, 40))
                    }
                    return col().key("root").wFull().children(children)
                }
            ).fitContentHeight()
            let treeURL = dir.appendingPathComponent("\(name).json")
            let args = ToolingArgs.parse([
                "--script", scriptURL.path,
                "--scale", "2",
                "--fps", "60",
                "--at", at,
                "--tree", treeURL.path,
            ])
            _ = try HeadlessRunner.run(app, args: args)
            let data = try Data(contentsOf: treeURL)
            let tree = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let vp = try #require(tree["viewport"] as? [NSNumber])
            return (vp[0].floatValue, vp[1].floatValue)
        }

        let openSize = try runViewport(name: "open", at: "0")
        #expect(openSize.0 == 300.0 && openSize.1 == 90.0)
        let movingSize = try runViewport(name: "moving", at: "0.3")
        #expect(movingSize.1 > 90.0 && movingSize.1 < 130.0)
        let landedSize = try runViewport(name: "landed", at: "2")
        #expect(landedSize.0 == 300.0 && landedSize.1 == 130.0)
    }

    @Test("tooling/tests.rs:459 - desktop_composites_each_window_at_its_frame_with_a_shadow")
    @MainActor
    func desktopCompositesEachWindowAtItsFrameWithShadow() throws {
        let dir = try makeTempDir("rune-desktop-shadow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backdrop = dir.appendingPathComponent("backdrop.png")
        let grey = Array(repeating: [UInt8]([128, 128, 128, 255]), count: 240 * 160).flatMap { $0 }
        try writeRGBAPNG(at: backdrop, width: 240, height: 160, rgba: grey)
        let script = dir.appendingPathComponent("script.json")
        try Data(#"[{"t": 0.1, "type": "tap", "x": 45, "y": 35}]"#.utf8).write(to: script)

        let redColor = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blueColor = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        func fillApp(_ c: Color) -> App<Color> {
            App<Color>("fill", size: Vec2(1, 1), init: { c }, view: { c, _ in El<Color>().wFull().hFull().bg(c) })
        }

        func render(_ name: String) throws -> Data {
            let snap = dir.appendingPathComponent(name)
            let args = [
                "--desktop", backdrop.path,
                "--script", script.path,
                "--scale", "2",
                "--at", "0.5",
                "--snap", snap.path,
            ]
            try runWindowsWithArgs(options: RunOptions(), arguments: args) { (displays: [DisplayInfo]) in
                #expect(displays.count == 1)
                #expect(displays[0].size.0 == 240 && displays[0].size.1 == 160)
                let back = AppWindowSpec<Color>.fromApp("back", fillApp(redColor))
                    .options(WindowOptions(position: (40, 40), physicalSize: (100, 60)))
                let panel = AppWindowSpec<Color>.fromApp("panel", fillApp(blueColor))
                    .configuredOptions(
                        WindowOptions(borderless: true, position: (160, 100), physicalSize: (40, 40))
                            .macos(MacWindowOptions(shadow: false))
                    )
                return [back.boxed(), panel.boxed()]
            }
            return try Data(contentsOf: snap)
        }

        let bytesA = try render("a.png")
        let bytesB = try render("b.png")
        #expect(bytesA == bytesB)

        let png = try readRGBAPNG(at: dir.appendingPathComponent("a.png"))
        #expect(png.width == 240 && png.height == 160)
        func px(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * png.width + x) * 4
            return Array(png.rgba[i..<(i + 4)])
        }
        func isRed(_ p: [UInt8]) -> Bool { p[0] > 245 && p[1] < 10 && p[2] < 10 }
        func isBlue(_ p: [UInt8]) -> Bool { p[2] > 245 && p[0] < 10 && p[1] < 10 }

        #expect(isRed(px(90, 70)) && isRed(px(40, 70)) && isRed(px(139, 70)) && isRed(px(90, 40)) && isRed(px(90, 99)))
        #expect(!isRed(px(39, 70)) && !isRed(px(140, 70)) && !isRed(px(90, 100)))
        #expect(isBlue(px(160, 100)))
        #expect(isBlue(px(199, 139)))
        #expect(isBlue(px(180, 120)))
        #expect(!isRed(px(40, 40)))
        let below = px(90, 106)
        #expect(below[0] < 112 && below[0] == below[2])
        #expect(px(180, 146) == [128, 128, 128, 255])
        #expect(px(4, 156) == [128, 128, 128, 255])

        let run = try #require(HeadlessRun.current)
        #expect(run.desktopPath == backdrop.path)
        let backFrame = try #require(run.windowsAt(0.5).first { $0.key == "back" })
        #expect(backFrame.frame == [20.0, 20.0, 50.0, 30.0] && backFrame.visible && backFrame.focused)
        #expect(run.windows.contains { $0.key == "panel" && $0.focused && $0.t == 0.0 })
    }

    @Test("tooling/tests.rs:559 - desktop_frame_shows_what_a_handler_did_to_another_window_that_frame")
    @MainActor
    func desktopFrameShowsWhatHandlerDidToAnotherWindowThatFrame() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let green = Color(r: 0.0, g: 1.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)

        let res = try runDesktopCase(
            name: "stale",
            script: #"[{"t": 0.1, "type": "key", "name": "Enter"}]"#,
            at: 0.1
        ) {
            let (notes, handle) = makeDesktopPair(name: "notes", color: red, options: Self.desktopLeft())
            let (launcher, _) = makeDesktopPair(name: "launcher", color: blue, other: handle, act: { notes, tx in
                notes.update { p, innerTx in
                    p.color = green
                    innerTx.instant()
                }
                notes.focus()
                tx.closeWindow()
            }, options: Self.desktopRight())
            return [notes.boxed(), launcher.boxed()]
        }
        Self.desktopLogLock.lock()
        let keyed = Self.desktopKeyed
        Self.desktopLogLock.unlock()
        #expect(keyed == ["launcher"])
        let i = (50 * res.width + 70) * 4
        #expect(res.rgba[i + 1] > 245 && res.rgba[i] < 10)
        #expect(Self.desktopFocusOf(res.run, at: 0.1, key: "notes") == (true, true))
        #expect(Self.desktopFocusOf(res.run, at: 0.1, key: "launcher") == (false, false))
    }

    @Test("tooling/tests.rs:579 - desktop_window_closing_itself_on_blur_closes_in_that_frame")
    @MainActor
    func desktopWindowClosingItselfOnBlurClosesInThatFrame() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)

        let script1 = #"[{"t": 0.1, "type": "tap", "x": 30, "y": 25}, {"t": 0.2, "type": "key", "name": "Enter"}]"#
        let res1 = try runDesktopCase(name: "blur", script: script1, at: 0.2) {
            let (b, handle) = makeDesktopPair(name: "b", color: blue, options: Self.desktopRight())
            let (a, _) = makeDesktopPair(
                name: "a",
                color: red,
                other: handle,
                act: { b, _ in b.focus() },
                options: Self.desktopLeft(),
                onFocus: { _, focused, tx in
                    if !focused { tx.closeWindow() }
                }
            )
            return [a.boxed(), b.boxed()]
        }
        #expect(Self.desktopFocusOf(res1.run, at: 0.1, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(res1.run, at: 0.2, key: "a") == (false, false))
        #expect(Self.desktopFocusOf(res1.run, at: 0.2, key: "b") == (true, true))
        let p1Idx = (50 * res1.width + 40) * 4
        #expect(Array(res1.rgba[p1Idx..<(p1Idx + 4)]) == [128, 128, 128, 255])

        let res2 = try runDesktopCase(
            name: "blur-open",
            script: #"[{"t": 0.1, "type": "key", "name": "Enter"}]"#,
            at: 0.1
        ) {
            var hiddenRight = Self.desktopRight()
            hiddenRight.visible = false
            let (c, handle) = makeDesktopPair(name: "c", color: blue, options: hiddenRight)
            let (a, _) = makeDesktopPair(
                name: "a",
                color: red,
                other: handle,
                act: { _, tx in tx.closeWindow() },
                options: Self.desktopLeft(),
                onFocus: { p, focused, _ in
                    if !focused, let c = p.other { c.open() }
                }
            )
            return [c.boxed(), a.boxed()]
        }
        #expect(Self.desktopFocusOf(res2.run, at: 0.1, key: "a") == (false, false))
        #expect(Self.desktopFocusOf(res2.run, at: 0.1, key: "c") == (true, true))
        let p2Idx = (70 * res2.width + 190) * 4
        #expect(res2.rgba[p2Idx + 2] > 245 && res2.rgba[p2Idx] < 10)
    }

    @Test("tooling/tests.rs:605 - desktop_click_on_the_backdrop_deactivates_the_app_until_it_refocuses")
    @MainActor
    func desktopClickOnBackdropDeactivatesAppUntilRefocuses() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let script = """
        [
            {"t": 0.1, "type": "tap", "x": 110, "y": 75},
            {"t": 0.2, "type": "key", "name": "Enter"},
            {"t": 0.3, "focus": true},
            {"t": 0.4, "type": "key", "name": "Enter"}
        ]
        """
        let dir = try makeTempDir("rune-desktop-tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let treeURL = dir.appendingPathComponent("tree.json")

        let res1 = try runDesktopCase(name: "inactive", script: script, at: 0.2, extra: ["--tree", treeURL.path]) {
            [makeDesktopPair(name: "a", color: red, options: Self.desktopLeft()).0.boxed()]
        }
        let tree = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: treeURL)) as? [String: Any])
        let windows = try #require(tree["windows"] as? [[String: Any]])
        #expect((windows[0]["focused"] as? Bool) == false)
        #expect(Self.desktopFocusOf(res1.run, at: 0.0, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(res1.run, at: 0.2, key: "a") == (true, false))
        Self.desktopLogLock.lock()
        let emptyKeyed = Self.desktopKeyed
        Self.desktopLogLock.unlock()
        #expect(emptyKeyed.isEmpty)

        let res2 = try runDesktopCase(name: "inactive2", script: script, at: 0.5) {
            [makeDesktopPair(name: "a", color: red, options: Self.desktopLeft()).0.boxed()]
        }
        #expect(Self.desktopFocusOf(res2.run, at: 0.3, key: "a") == (true, true))
        Self.desktopLogLock.lock()
        let finalKeyed = Self.desktopKeyed
        Self.desktopLogLock.unlock()
        #expect(finalKeyed == ["a"])
    }

    @Test("tooling/tests.rs:630 - desktop_click_through_window_never_takes_the_keyboard")
    @MainActor
    func desktopClickThroughWindowNeverTakesKeyboard() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let script = #"[{"t": 0.1, "type": "key", "name": "Enter"}, {"t": 0.2, "type": "key", "name": "Enter"}]"#
        let res = try runDesktopCase(name: "hud", script: script, at: 0.3) {
            var hudOpts = Self.desktopRight()
            hudOpts.visible = false
            hudOpts.clickThrough = true
            hudOpts.borderless = true
            let (hud, handle) = makeDesktopPair(name: "hud", color: blue, options: hudOpts)
            let (a, _) = makeDesktopPair(name: "a", color: red, other: handle, act: { h, _ in
                h.open()
                h.focus()
            }, options: Self.desktopLeft())
            return [a.boxed(), hud.boxed()]
        }
        #expect(Self.desktopFocusOf(res.run, at: 0.1, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(res.run, at: 0.1, key: "hud") == (true, false))
        Self.desktopLogLock.lock()
        let keyed = Self.desktopKeyed
        Self.desktopLogLock.unlock()
        #expect(keyed == ["a", "a"])
    }

    private func recordReopenHook(_ p: inout DesktopPair, _ visible: Bool, _ tx: inout Tx) -> Bool {
        Self.desktopLogLock.lock()
        Self.desktopReopened.append((p.name, visible))
        Self.desktopLogLock.unlock()
        return false
    }

    private func handleReopenHook(_ p: inout DesktopPair, _ visible: Bool, _ tx: inout Tx) -> Bool {
        _ = recordReopenHook(&p, visible, &tx)
        return true
    }

    @Test("tooling/tests.rs:692 - desktop_reopen_shows_the_window_closed_last_with_the_keyboard")
    @MainActor
    func desktopReopenShowsWindowClosedLastWithKeyboard() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let script = #"[{"t": 0.1, "type": "key", "name": "Enter"}, {"t": 0.2, "type": "key", "name": "Enter"}, {"t": 0.3, "reopen": true}]"#
        let run = try runReopenCase(script: script, accessory: false) {
            [
                makeCloser(name: "a", color: red, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions())).0,
                makeCloser(name: "b", color: blue, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopRight().macos(MacWindowOptions())).0,
            ]
        }
        #expect(Self.desktopFocusOf(run, at: 0.2, key: "a") == (false, false))
        #expect(Self.desktopFocusOf(run, at: 0.2, key: "b") == (false, false))
        #expect(Self.desktopFocusOf(run, at: 0.3, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(run, at: 0.3, key: "b") == (false, false))
        Self.desktopLogLock.lock()
        let reopened = Self.desktopReopened
        Self.desktopLogLock.unlock()
        #expect(reopened.count == 2 && reopened[0].0 == "a" && !reopened[0].1 && reopened[1].0 == "b" && !reopened[1].1)
        #expect(run.events.contains { if case .reopen = $0.event { return true }; return false })
    }

    @Test("tooling/tests.rs:706 - desktop_reopen_with_a_window_showing_changes_nothing")
    @MainActor
    func desktopReopenWithWindowShowingChangesNothing() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let script = #"[{"t": 0.1, "type": "key", "name": "Enter"}, {"t": 0.2, "reopen": true}]"#
        let run = try runReopenCase(script: script, accessory: false) {
            [
                makeCloser(name: "a", color: red, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions())).0,
                makeCloser(name: "b", color: blue, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopRight().macos(MacWindowOptions())).0,
            ]
        }
        #expect(Self.desktopFocusOf(run, at: 0.2, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(run, at: 0.2, key: "b") == (false, false))
        Self.desktopLogLock.lock()
        let reopened = Self.desktopReopened
        Self.desktopLogLock.unlock()
        #expect(reopened.count == 2 && reopened[0].0 == "a" && reopened[0].1 && reopened[1].0 == "b" && reopened[1].1)
    }

    @Test("tooling/tests.rs:716 - desktop_reopen_default_sees_what_the_hooks_did")
    @MainActor
    func desktopReopenDefaultSeesWhatHooksDid() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let script = #"[{"t": 0.1, "type": "tap", "x": 30, "y": 25}, {"t": 0.2, "type": "key", "name": "Enter"}, {"t": 0.3, "type": "key", "name": "Enter"}, {"t": 0.4, "reopen": true}]"#
        let run = try runReopenCase(script: script, accessory: false) {
            let (a, handle) = makeCloser(name: "a", color: red, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions()))
            let (b, _) = makeCloser(name: "b", color: blue, other: handle, hook: { p, v, tx in
                if let other = p.other { other.open() }
                return recordReopenHook(&p, v, &tx)
            }, options: Self.desktopRight().macos(MacWindowOptions()))
            return [a, b]
        }
        #expect(Self.desktopFocusOf(run, at: 0.3, key: "a") == (false, false))
        #expect(Self.desktopFocusOf(run, at: 0.3, key: "b") == (false, false))
        #expect(Self.desktopFocusOf(run, at: 0.4, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(run, at: 0.4, key: "b") == (false, false))
        Self.desktopLogLock.lock()
        let reopened = Self.desktopReopened
        Self.desktopLogLock.unlock()
        #expect(reopened.count == 2 && reopened[0].0 == "a" && !reopened[0].1 && reopened[1].0 == "b" && !reopened[1].1)
    }

    @Test("tooling/tests.rs:733 - desktop_reopen_hook_that_handles_it_skips_the_default")
    @MainActor
    func desktopReopenHookThatHandlesItSkipsDefault() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let script = #"[{"t": 0.1, "type": "key", "name": "Enter"}, {"t": 0.2, "reopen": true}]"#
        let run = try runReopenCase(script: script, accessory: false) {
            [makeCloser(name: "a", color: red, hook: { p, v, tx in handleReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions())).0]
        }
        #expect(Self.desktopFocusOf(run, at: 0.2, key: "a") == (false, false))
        Self.desktopLogLock.lock()
        let reopened = Self.desktopReopened
        Self.desktopLogLock.unlock()
        #expect(reopened.count == 1 && reopened[0].0 == "a" && !reopened[0].1)
    }

    @Test("tooling/tests.rs:742 - desktop_reopen_never_brings_back_a_launcher_or_an_accessory_app_window")
    @MainActor
    func desktopReopenNeverBringsBackLauncherOrAccessoryWindow() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)

        func makeLauncher() -> AnyWindowSpec {
            var opts = WindowOptions.launcherPanel()
            opts.options.visible = true
            opts.options.position = Self.desktopRight().position
            opts.options.physicalSize = Self.desktopRight().physicalSize
            return makeCloser(name: "launcher", color: blue, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: opts).0
        }

        let script1 = #"[{"t": 0.1, "type": "tap", "x": 30, "y": 25}, {"t": 0.2, "type": "key", "name": "Enter"}, {"t": 0.3, "type": "tap", "x": 95, "y": 35}, {"t": 0.4, "type": "key", "name": "Enter"}, {"t": 0.5, "reopen": true}]"#
        let run1 = try runReopenCase(script: script1, accessory: false) {
            [makeCloser(name: "a", color: red, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions())).0, makeLauncher()]
        }
        #expect(Self.desktopFocusOf(run1, at: 0.4, key: "a") == (false, false))
        #expect(Self.desktopFocusOf(run1, at: 0.4, key: "launcher") == (false, false))
        #expect(Self.desktopFocusOf(run1, at: 0.5, key: "a") == (true, true))
        #expect(Self.desktopFocusOf(run1, at: 0.5, key: "launcher") == (false, false))

        let script2 = #"[{"t": 0.1, "type": "tap", "x": 95, "y": 35}, {"t": 0.2, "type": "key", "name": "Enter"}, {"t": 0.3, "reopen": true}]"#
        let run2 = try runReopenCase(script: script2, accessory: false) {
            [makeLauncher()]
        }
        #expect(Self.desktopFocusOf(run2, at: 0.3, key: "launcher") == (false, false))

        let script3 = #"[{"t": 0.1, "type": "key", "name": "Enter"}, {"t": 0.2, "reopen": true}]"#
        let run3 = try runReopenCase(script: script3, accessory: true) {
            [makeCloser(name: "a", color: red, hook: { p, v, tx in recordReopenHook(&p, v, &tx) }, options: Self.desktopLeft().macos(MacWindowOptions())).0]
        }
        #expect(Self.desktopFocusOf(run3, at: 0.2, key: "a") == (false, false))
        Self.desktopLogLock.lock()
        let reopened3 = Self.desktopReopened
        Self.desktopLogLock.unlock()
        #expect(reopened3.count == 1 && reopened3[0].0 == "a" && !reopened3[0].1)
    }

    @Test("virtual_desktop/window.rs:354 - runReopenHook skips permanently closed windows")
    func desktopWindowRunReopenHookSkipsFinishedWindow() {
        let app = App<Int>(title: "Finished", size: Vec2(200, 120), state: 0) { _, _ in
            el().size(200, 120)
        }
        .onReopen { count, _, _ in
            count += 1
            return true
        }
        let win = DesktopWindow<Int>(key: "finished", app: app, scale: 1.0)
        win.start(desktop: .single(scale: 1.0))
        #expect(win.reopenCandidate().reopenable)
        #expect(win.runReopenHook(hasVisibleWindows: false))
        #expect(win.runtime.state == 1)

        win.close()
        #expect(!win.reopenCandidate().reopenable)
        #expect(!win.runReopenHook(hasVisibleWindows: false))
        #expect(win.runtime.state == 1)
    }
}
