import Foundation
import Testing
@testable import Rune
@testable import RuneLuau
import RuneMotion

private struct LuauTestState {}

private func findElement<S>(_ root: El<S>, where predicate: (El<S>) -> Bool) -> El<S>? {
    if predicate(root) { return root }
    for child in root.children {
        if let found = findElement(child, where: predicate) { return found }
    }
    return nil
}

private func collectTexts<S>(_ root: El<S>) -> [String] {
    var out: [String] = []
    if let t = root.plainText { out.append(t) }
    for child in root.children {
        out.append(contentsOf: collectTexts(child))
    }
    return out
}

private func dataList(_ data: LuauData) -> [LuauData] {
    if case .list(let items) = data { return items }
    return []
}

@Suite("RuneLuau Parity Tests")
struct RuneLuauParityTests {

    @Test("P0: virtualList scrolls beyond 0/600, lazily evaluates rowKey, respects scrollY=false, fires onVisibleRows, and increments metrics.rows")
    func virtualListScrollLazyAndInline() throws {
        let script = Script(
            name: "vlist",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local rowKeyCalls = 0
            local visibleRanges = {}
            return {
                render = function(view)
                    return ui.col({ w = "full", h = "full" }, {
                        ui.virtualList({
                            key = "items",
                            count = 500,
                            estimatedRowHeight = 20,
                            rowKey = function(i)
                                rowKeyCalls += 1
                                return "k-" .. i
                            end,
                            renderRow = function(i)
                                return ui.text("row-" .. i, { key = "r-" .. i })
                            end,
                            onVisibleRows = function(ev)
                                table.insert(visibleRanges, { kind = ev.kind, first = ev.first, last = ev.last })
                            end,
                            onPress = function() end,
                        }),
                    })
                end,
                inlineList = function(view)
                    return ui.col({ w = "full" }, {
                        ui.virtualList({
                            key = "inline",
                            count = 5,
                            scrollY = false,
                            estimatedRowHeight = 20,
                            renderRow = function(i)
                                return ui.text("inline-" .. i)
                            end,
                        }),
                    })
                end,
                stats = function()
                    return { rowKeyCalls = rowKeyCalls, ranges = visibleRanges }
                end,
            }
            """)
        )
        #expect(script.error == nil)

        var currentScrollY: Float = 0
        let cx0 = Cx<LuauTestState>(
            viewport: Vec2(400, 200),
            scrollLookup: { _ in Vec2(0, currentScrollY) }
        )
        let el0 = script.view(cx0)
        let texts0 = collectTexts(el0)
        #expect(texts0.contains("row-1"))
        #expect(!texts0.contains("row-250"))

        let statsAfterFirst = try script.query("stats")
        let initialRowKeyCalls = statsAfterFirst.get("rowKeyCalls").asInt64 ?? 0
        #expect(initialRowKeyCalls > 0)
        #expect(initialRowKeyCalls < 60) // Lazy: did NOT call rowKey 500 times
        let initialRowsMetric = script.metrics.rows
        #expect(initialRowsMetric > 0 && initialRowsMetric < 60)

        // Scroll deep into the 500-row list (beyond hardcoded 0/600!)
        currentScrollY = 4000
        let cx1 = Cx<LuauTestState>(
            viewport: Vec2(400, 200),
            scrollLookup: { _ in Vec2(0, currentScrollY) }
        )
        let el1 = script.view(cx1)
        let texts1 = collectTexts(el1)
        #expect(!texts1.contains("row-1"))
        #expect(texts1.contains("row-201") || texts1.contains("row-200") || texts1.contains("row-202"))

        let listContainer = findElement(el1) { $0.keyId == "\(script.memoPrefix())items" }
        #expect(listContainer != nil)
        #expect(listContainer?.layout.scrollAxes.contains(.vertical) == true)

        let statsAfterScroll = try script.query("stats")
        let ranges = dataList(statsAfterScroll.get("ranges"))
        #expect(ranges.count >= 2)
        let lastRange = ranges.last
        #expect(lastRange?.get("kind").asString == "visible-rows")
        let secondFirst = lastRange?.get("first").asInt64 ?? 0
        #expect(secondFirst > 100)
        #expect(script.metrics.rows > initialRowsMetric)
        #expect(script.log.contains { $0.level == .warn && $0.message == "ui.virtualList takes no onPress" })

        // Inline virtualList (`scrollY = false`) must NOT mark .scrollY()
        let inlineEl = script.surface(cx0, name: "inlineList")
        let inlineContainer = findElement(inlineEl) { $0.keyId == "\(script.memoPrefix())inline" }
        #expect(inlineContainer != nil)
        #expect(inlineContainer?.layout.scrollAxes.contains(.vertical) == false)
    }

    @Test("Mounted Luau virtual rows scroll in Rune without reevaluating the script's surface")
    func mountedVirtualListUsesRuntimeRows() throws {
        final class Reads: @unchecked Sendable { var sawState = false }
        let reads = Reads()
        var options = ScriptOptions()
        options.aroundRead = { state, run in
            if state is LuauTestState { reads.sawState = true }
            run()
        }
        let sources = Sources.single("""
            local ui = require("@rune/ui")
            local builds = 0
            local last = 0
            local function visible(e) last = e.last end
            return {
                render = function()
                    builds += 1
                    return ui.col({ w = "full", h = "full" }, {
                        ui.virtualList({ key = "items", h = "full", count = 100000,
                            estimatedRowHeight = 24, version = 1,
                            renderRow = function(i)
                                return ui.text("row " .. i, {h = 24})
                            end,
                            onVisibleRows = visible })
                    })
                end,
                stopReporting = function() visible = nil end,
                metrics = function() return {builds = builds, last = last} end,
            }
            """)
        let script = Script(name: "mounted-rows", sources: sources, options: options)
        let runtime = Runtime(state: LuauTestState(), viewport: Vec2(260, 120)) { _, cx in script.view(cx) }
        _ = runtime.frame(at: 0)
        let initialBuilds = script.metrics.renders
        #expect(initialBuilds > 0 && reads.sawState)
        #expect(runtime.elements().contains { $0.text == "row 1" })
        #expect(script.metrics.rows > 0 && script.metrics.rows < 100)
        for step in 1...10 {
            let now = Double(step) / 120
            runtime.wheel(WheelEvent(dy: -320), at: Vec2(40, 40), now: now)
            _ = runtime.frame(at: now)
        }
        let final = try script.query("metrics")
        #expect((final.get("last").asInt64 ?? 0) > 100)
        #expect(!runtime.elements().contains { $0.text == "row 1" })
        #expect(runtime.elements().count < 350)
        #expect(script.metrics.rows < 650)

        // Mount a list that has never reported a range. A reporting handler can
        // legitimately invalidate its surface while the runtime delivers its last update.
        let silent = Script(name: "silent-rows", sources: sources, options: options)
        try silent.call("stopReporting")
        let silentRuntime = Runtime(state: LuauTestState(), viewport: Vec2(260, 120)) { _, cx in silent.view(cx) }
        _ = silentRuntime.frame(at: 0)
        let initialSilentBuilds = silent.metrics.renders
        #expect(initialSilentBuilds == 1)
        for step in 1...4 {
            let now = Double(step) / 120
            silentRuntime.wheel(WheelEvent(dy: -320), at: Vec2(40, 40), now: now)
            _ = silentRuntime.frame(at: now)
        }
        #expect(!silentRuntime.elements().contains { $0.text == "row 1" })
        #expect(silent.metrics.renders == initialSilentBuilds)
        #expect(try silent.query("metrics").get("last").asInt64 == 0)
    }

    @Test("P0: children accept false/number, reject true/reuse/stale elements")
    func childrenValidationAndReuse() throws {
        let script = Script(
            name: "children",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            return {
                render = function()
                    return ui.row({
                        "hello",
                        false,
                        42,
                        nil,
                        ui.text("tail"),
                    })
                end,
                reuse = function()
                    local child = ui.text("once")
                    return ui.row({ child, child })
                end,
                boolTrue = function()
                    return ui.row({ true })
                end,
            }
            """)
        )
        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let okEl = script.surface(cx, name: "render")
        #expect(collectTexts(okEl) == ["hello", "42", "tail"])

        let reuseEl = script.surface(cx, name: "reuse")
        let reuseTexts = collectTexts(reuseEl).joined(separator: " ")
        #expect(reuseTexts.contains("each element can only be placed once"))

        let trueEl = script.surface(cx, name: "boolTrue")
        let trueTexts = collectTexts(trueEl).joined(separator: " ")
        #expect(trueTexts.contains("child 1 is a boolean, not a ui node"))
    }

    @Test("P0: unknown colour warns once and returns transparent; bad #hex fails render")
    func colorResolutionAndWarnings() throws {
        let script = Script(
            name: "colors",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            return {
                render = function()
                    return ui.row({ fill = "nonexistent-token", hover = "nonexistent-token" }, {
                        ui.text("ok", { color = "text" }),
                    })
                end,
                badHex = function()
                    return ui.box({ fill = "#zzzzzz" })
                end,
            }
            """)
        )
        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let okEl = script.surface(cx, name: "render")
        let rowEl = findElement(okEl) { !$0.children.isEmpty }
        #expect(collectTexts(okEl).contains("ok"))
        // Unknown palette token falls back to transparent instead of failing render
        let warnLogs = script.log.filter { $0.level == .warn && $0.message == "unknown colour nonexistent-token" }
        #expect(warnLogs.count == 1)
        _ = rowEl

        // Invalid hex literal must still fail the render with upstream message
        let badEl = script.surface(cx, name: "badHex")
        let badText = collectTexts(badEl).joined(separator: " ")
        #expect(badText.contains("#zzzzzz is not a #rrggbb or #rrggbbaa colour"))
    }

    @Test("P0: Script exposes version, vmId, module, renderFn, spawnFn, evalFn, prewarm, reloadCompiled, memory")
    func functionsModuleAndPrewarmAPI() throws {
        let script = Script(
            name: "fns",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local count = 10
            return {
                inc = function(delta)
                    count += delta
                    return count
                end,
                getCount = function()
                    return count
                end,
                drawWidget = function(view, label)
                    return ui.text(label .. ":" .. count)
                end,
            }
            """)
        )
        #expect(script.version >= 1)
        #expect(script.vmId != nil)
        #expect(script.module != nil)
        #expect(script.memory() > 0)

        let drawFn = script.module!.rawGet("drawWidget")
        let incFn = script.module!.rawGet("inc")
        let getFn = script.module!.rawGet("getCount")

        let el: El<LuauTestState> = script.renderFn(
            "widget",
            version: 1,
            dark: false,
            fn: drawFn,
            args: [.string("v")]
        )
        #expect(collectTexts(el) == ["v:10"])

        var tx = Tx()
        try script.spawnFn(incFn, args: [.number(5)], tx: &tx)
        let verBeforeEval = script.version
        let out = try script.evalFn(getFn)
        #expect(out.first?.asInt == 15)
        #expect(script.version == verBeforeEval)

        let el2: El<LuauTestState> = script.renderFn(
            "widget",
            version: 2,
            dark: false,
            fn: drawFn,
            args: [.string("v")]
        )
        #expect(collectTexts(el2) == ["v:15"])

        // prewarm + reloadCompiled
        let oldVMId = script.vmId
        script.prewarm()
        let nextSrc = Sources.single("""
        local count = 99
        return { getCount = function() return count end }
        """)
        let compiled = try nextSrc.compile()
        let report = try script.reloadCompiled(nextSrc, compiled: compiled, compileDuration: .milliseconds(3))
        #expect(report.compileDuration == .milliseconds(3))
        #expect(script.vmId != oldVMId)
        #expect(try script.query("getCount").asInt64 == 99)
        #expect(script.log.contains { $0.level == .info && $0.message.contains("reloaded in ") })
    }

    @Test("P1: @rune/ui can be captured at module load time, throws outside render, and host nodes apply unread props")
    func preRequireAndHostNodesUnreadProps() throws {
        let hostNode = HostNode(name: "badge") { args in
            let text = args.content ?? args.string("text") ?? ""
            return (Rune.text("[\(text)]") as El<LuauTestState>)
        }
        let failingNode = HostNode(name: "broken") { _ -> El<LuauTestState> in
            throw ScriptError(kind: .runtime, message: "bad config")
        }

        let script = Script(
            name: "host",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local badge = ui.badge
            local box = ui.box
            local outsideOk = pcall(box, {})
            local pressed = 0
            return {
                outsideOk = function() return outsideOk end,
                render = function()
                    return ui.col({
                        badge("new", {
                            key = "my-badge",
                            fill = "#112233",
                            onPress = function() pressed += 1 end,
                        }),
                    })
                end,
                failHost = function()
                    return ui.broken({})
                end,
                presses = function() return pressed end,
            }
            """),
            options: ScriptOptions().node(hostNode).node(failingNode)
        )
        #expect(try script.query("outsideOk").asBool == false)

        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let el = script.view(cx)
        let badge = findElement(el) { $0.keyId == "my-badge" }
        #expect(badge != nil)
        #expect(collectTexts(el).contains("[new]"))
        var state = LuauTestState()
        var tx = Tx()
        badge?.handlers.onClick?(&state, &tx)
        #expect(try script.query("presses").asInt64 == 1)

        let brokenEl = script.surface(cx, name: "failHost")
        #expect(collectTexts(brokenEl).joined(separator: " ").contains("ui.broken: bad config"))
    }

    @Test("menuTrigger dispatches ordinary and host Lua callbacks on mouse down and touch release")
    func menuTriggerPressTiming() throws {
        let host = HostNode(name: "menu") { (args: NodeArgs) -> El<LuauTestState> in
            args.onPress(el().key("host").size(100, 30).focusable(), "onPress")
        }
        var options = ScriptOptions()
        options.nodes = [host]
        let script = Script(name: "menu", sources: Sources.single("""
            local ui = require("@rune/ui")
            local n = 0
            local function hit(e)
                n += e.shift and 10 or 1
            end
            return {
                render = function()
                    return ui.col({
                        ui.box({key = "menu", w = 100, h = 30, focusable = true, menuTrigger = true, onPress = hit}),
                        ui.menu({menuTrigger = true, onPress = hit}),
                    })
                end,
                count = function() return n end,
            }
            """), options: options)
        let rt = Runtime(state: LuauTestState(), viewport: Vec2(200, 160)) { _, cx in
            script.view(cx)
        }
        _ = rt.frame(at: 0)
        let shift = Mods(shift: true)
        for (index, key) in ["menu", "host"].enumerated() {
            let rect = try #require(rt.element(byKey: key)).rect
            let p = Vec2(rect[0] + 8, rect[1] + 8)
            let now = Double(index + 1)
            let before = Int64(index * 14)
            rt.pointerDown(at: p, mods: shift, at: now)
            #expect(try script.query("count").asInt64 == before + 10)
            rt.pointerUp(at: p, at: now + 0.01)
            #expect(try script.query("count").asInt64 == before + 10)
            rt.touch(id: 1, phase: .started, at: p, time: now + 0.2)
            #expect(try script.query("count").asInt64 == before + 10)
            rt.touch(id: 1, phase: .ended, at: p, time: now + 0.25)
            #expect(try script.query("count").asInt64 == before + 11)
            #expect(rt.keyDown(KeyEvent(key: .space), at: now + 0.3))
            #expect(try script.query("count").asInt64 == before + 12)
            rt.pointerDown(at: p, at: now + 0.4)
            rt.cancelPointer(at: now + 0.42)
            #expect(try script.query("count").asInt64 == before + 13)
            rt.pointerDown(at: p, at: now + 0.5)
            rt.pointerReleaseLost(at: p, at: now + 0.52)
            #expect(try script.query("count").asInt64 == before + 14)
        }
    }

    @Test("P1: onPress delivers real modifier keys via onPointerUp + onClick inside around hook")
    func realPressModsAndAroundHooks() throws {
        final class HookBox: @unchecked Sendable {
            var writes = 0
            var reads = 0
        }
        let hooks = HookBox()
        let opts = ScriptOptions()
            .around { state, tx, run in
                hooks.writes += 1
                run(tx)
                _ = state
            }
            .aroundRead { _, run in
                hooks.reads += 1
                run()
            }

        let script = Script(
            name: "mods",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local last = nil
            return {
                render = function()
                    return ui.row({
                        ui.box({
                            key = "btn",
                            onPress = function(ev)
                                last = ev
                            end,
                        }),
                    })
                end,
                lastEvent = function() return last end,
            }
            """),
            options: opts
        )
        let cx = Cx<LuauTestState>(viewport: Vec2(200, 100))
        let el = script.view(cx)
        #expect(hooks.reads == 0)

        let btn = findElement(el) { $0.keyId == "btn" }
        #expect(btn != nil)
        var state = LuauTestState()
        var tx = Tx()
        #if os(macOS)
        let press = PointerPress(window: .zero, local: .zero, elementSize: Vec2(50, 20), mods: Mods(shift: true, ctrl: false, alt: true, cmd: true))
        #else
        let press = PointerPress(window: .zero, local: .zero, elementSize: Vec2(50, 20), mods: Mods(shift: true, ctrl: true, alt: true, cmd: false))
        #endif
        btn?.handlers.onPointerUp?(&state, press, &tx)
        btn?.handlers.onClick?(&state, &tx)
        #expect(hooks.writes == 1)

        let ev = try script.query("lastEvent")
        #expect(ev.get("shift").asBool == true)
        #expect(ev.get("alt").asBool == true)
        #expect(ev.get("mod").asBool == true)
    }

    @Test("P1/P2: sandbox freezes globals, memoryLimit trips ErrorKind.memory, ui.each propagates error, props & roles validate")
    func sandboxMemoryEachAndPropValidation() throws {
        let script = Script(
            name: "safety",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local okMutateStdlib = pcall(function() table.insert = function() end end)
            local okMutateStringMt = pcall(function() getmetatable("").__index.sub = nil end)
            return {
                sandboxed = function()
                    return { stdlib = okMutateStdlib, strMt = okMutateStringMt }
                end,
                allocBig = function()
                    return table.create(500000, 1)
                end,
                badEach = function()
                    return ui.col({}, ui.each({ { id = 1, v = 1 } }, "id", "v", function()
                        error("boom in each")
                    end))
                end,
                propsCheck = function()
                    return ui.row({ shrink = false, unknownPropOne = 1, unknownPropOne2 = 1, role = "link" }, {
                        ui.text("hello", { wrap = false, tabular = true, selectable = true, dir = "ltr" }),
                    })
                end,
                badRole = function()
                    return ui.box({ role = "spaceship" })
                end,
                badFadeOut = function()
                    return ui.box({ fadeOut = 1 })
                end,
                badHoverGroup = function()
                    return ui.box({ hoverGroup = "nav" })
                end,
            }
            """),
            options: ScriptOptions().memoryLimit(256 * 1024)
        )
        let s = try script.query("sandboxed")
        #expect(s.get("stdlib").asBool == false)
        #expect(s.get("strMt").asBool == false)

        var memErr: ScriptError?
        do {
            _ = try script.query("allocBig")
        } catch let e as ScriptError {
            memErr = e
        }
        #expect(memErr?.kind == .memory)

        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let eachErr = collectTexts(script.surface(cx, name: "badEach")).joined(separator: " ")
        #expect(eachErr.contains("boom in each"))

        let propsEl = script.surface(cx, name: "propsCheck")
        let rowEl = findElement(propsEl) { $0.role == .link }
        #expect(rowEl != nil)
        let helloEl = findElement(propsEl) { $0.plainText == "hello" }
        #expect(helloEl?.textStyle.wrap == .noWrap)
        #expect(helloEl?.textStyle.features == "'tnum' 1")
        #expect(script.log.contains { $0.level == .warn && $0.message == "unknown prop unknownPropOne" })

        let roleErr = collectTexts(script.surface(cx, name: "badRole")).joined(separator: " ")
        #expect(roleErr.contains("unknown role spaceship"))
        let fadeErr = collectTexts(script.surface(cx, name: "badFadeOut")).joined(separator: " ")
        #expect(fadeErr.contains("fadeOut"))
        let hoverErr = collectTexts(script.surface(cx, name: "badHoverGroup")).joined(separator: " ")
        #expect(hoverErr.contains("hoverGroup"))
    }

    @Test("P1/P2: .config.luau aliases, deterministic timer ordering, unforgeable tokens, and watch in-place reload")
    func configLuauTimersAndWatch() throws {
        // 1. .config.luau + timer ordering + token forgery rejection
        let sources = Sources()
            .with(".config.luau", "return { luau = { aliases = { lib = './mods' } } }")
            .with("mods/greet.luau", "return 'hi'")
            .with("init.luau", """
            local g = require('@lib/greet')
            local order = {}
            task.delay(0.05, function() table.insert(order, 'second') end)
            task.delay(0.01, function() table.insert(order, 'first-a') end)
            task.delay(0.01, function() table.insert(order, 'first-b') end)
            local forgedDone = false
            task.spawn(function()
                coroutine.yield("__rune_task_park__")
                forgedDone = true
            end)
            return {
                result = function()
                    return { greet = g, order = order, forgedDone = forgedDone }
                end,
            }
            """)
        let script = Script(name: "timers", sources: sources)
        var tx = Tx()
        _ = script.poll(now: 0.02, tx: &tx)
        _ = script.poll(now: 0.06, tx: &tx)
        let res = try script.query("result")
        #expect(res.get("greet").asString == "hi")
        let order = dataList(res.get("order")).compactMap { $0.asString }
        #expect(order == ["first-a", "first-b", "second"])
        // Forged park string token does NOT park forever; resumes on next frame!
        #expect(res.get("forgedDone").asBool == true)

        // 2. Folder watch reloads on in-place file modification
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-luau-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entryURL = dir.appendingPathComponent("init.luau")
        try "return { v = function() return 1 end }".write(to: entryURL, atomically: false, encoding: .utf8)
        let diskSources = try Sources.fromDir(dir)
        let watched = Script(name: "watched", sources: diskSources)
        #expect(try watched.query("v").asInt64 == 1)
        try watched.watch(dir)

        Thread.sleep(forTimeInterval: 0.12)
        try "return { v = function() return 2 end }".write(to: entryURL, atomically: false, encoding: .utf8)

        var sawReload = false
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.05)
            var wtx = Tx()
            if watched.poll(now: 0.1, tx: &wtx) {
                sawReload = true
                break
            }
        }
        #expect(sawReload)
        #expect(try watched.query("v").asInt64 == 2)
    }

    @Test("propNames, view:Memo key/version validation & rekey, syntax path prefix, and math/bit32/utf8 additions")
    func propNamesViewMemoAndStdlibAdditions() throws {
        #expect(propNames().count == 77)
        #expect(propNames().contains("menuTrigger"))
        #expect(propNames().contains("fadeOut"))
        #expect(propNames().contains("onVisibleRows"))
        #expect(propNames().contains("onMiddlePress"))

        // onMiddlePress dispatches middle-press event with mods without firing onPress
        let midScript = Script(
            name: "mid_press_runtime",
            sources: Sources.single("""
                local ui = require("@rune/ui")
                local events = {}
                return {
                    render = function()
                        return ui.col({ w = 200, h = 100 }, {
                            ui.box({
                                key = "mid-box",
                                w = 120,
                                h = 40,
                                onPress = function(ev) table.insert(events, ev) end,
                                onMiddlePress = function(ev) table.insert(events, ev) end,
                            })
                        })
                    end,
                    events = function() return events end,
                }
                """)
        )
        let midRt = Runtime<LuauTestState>(state: LuauTestState(), viewport: Vec2(200, 100)) { _, cx in
            midScript.view(cx)
        }
        _ = midRt.frame(at: 0.0)
        let boxRect = try #require(midRt.element(byKey: "mid-box")).rect
        let boxPt = Vec2(boxRect[0] + 20, boxRect[1] + 20)
        midRt.pointerDown(at: boxPt, button: .middle, mods: Mods(shift: true, alt: true), at: 0.02)
        midRt.pointerUp(at: boxPt, button: .middle, mods: Mods(shift: true, alt: true), at: 0.03)
        _ = midRt.frame(at: 0.04)
        let midEvents = dataList(try midScript.query("events"))
        #expect(midEvents.count == 1)
        #expect(midEvents[0].get("kind").asString == "middle-press")
        #expect(midEvents[0].get("key").asString == "mid-box")
        #expect(midEvents[0].get("shift").asBool == true)
        #expect(midEvents[0].get("alt").asBool == true)
        #expect(midEvents[0].get("mod").asBool == false)

        // Sources syntax errors include the module path prefix
        let badSources = Sources().with("views/broken.luau", "local x = (")
            .with("init.luau", "return {}")
        do {
            _ = try badSources.compile()
            Issue.record("Expected compile syntax error")
        } catch let err as ScriptError {
            #expect(err.kind == .syntax)
            #expect(err.message.contains("views/broken.luau:"))
        }

        // view:Memo accepts numeric key, re-keys root, rejects table version; plus stdlib helpers
        let memoSources = Sources.single("""
            local ui = require("@rune/ui")
            return {
                helpers = function()
                    return {
                        lerp = math.lerp(10, 20, 0.25),
                        mapped = math.map(5, 0, 10, 100, 200),
                        isNan = math.isnan(0/0),
                        isInf = math.isinf(1/0),
                        isFin = math.isfinite(42),
                        swapped = bit32.byteswap(0x12345678),
                        uoff = utf8.offset("aé", 2),
                    }
                end,
                view = function(cx)
                    local good = cx:Memo(7, 1, function()
                        return ui.text("ok", { key = "inner" })
                    end)
                    return ui.col({ good })
                end,
                badVersion = function(cx)
                    return cx:Memo("k", {}, function()
                        return ui.text("nope")
                    end)
                end,
            }
            """)
        let script = Script(name: "memo_parity", sources: memoSources)
        let helpers = try script.query("helpers")
        #expect(helpers.get("lerp").asDouble == 12.5)
        #expect(helpers.get("mapped").asDouble == 150.0)
        #expect(helpers.get("isNan").asBool == true)
        #expect(helpers.get("isInf").asBool == true)
        #expect(helpers.get("isFin").asBool == true)
        #expect(helpers.get("swapped").asInt64 == 0x78563412)
        #expect(helpers.get("uoff").asInt64 == 2)

        let cx = Cx<LuauTestState>(viewport: Vec2(400, 200))
        let el = script.surface(cx, name: "view")
        let memoNode = findElement(el) { $0.keyId == "\(script.memoPrefix())7" }
        #expect(memoNode != nil)
        #expect(memoNode?.plainText == "ok")

        let badEl = script.renderUncached(name: "badVersion", dark: true, LuauTestState.self)
        #expect(findElement(badEl) { $0.keyId == "luau-error" } != nil)
    }

    @Test("Numeric element keys and markStack unwind after thrown call (#464)")
    func numericElementKeysAndMarkStackUnwind() throws {
        let script = Script(
            name: "num_key_and_markstack",
            sources: Sources.single("""
                local ui = require("@rune/ui")
                local function failVararg(...)
                    error("boom")
                end
                return {
                    render = function(cx)
                        return ui.col({
                            ui.col({ key = 42 }, {
                                ui.text("item", { key = 7 }),
                            }),
                        })
                    end,
                    probe = function()
                        local ok = pcall(function()
                            return { 1, 2, failVararg("a", "b") }
                        end)
                        local after = { "x", "y" }
                        return { ok = ok, count = #after, first = after[1], second = after[2] }
                    end,
                }
                """)
        )
        let cx = Cx<LuauTestState>(viewport: Vec2(400, 200))
        let root = script.surface(cx, name: "render")
        #expect(findElement(root) { $0.keyId == "42" } != nil)
        #expect(findElement(root) { $0.keyId == "7" }?.plainText == "item")

        let probe = try script.query("probe")
        #expect(probe.get("ok").asBool == false)
        #expect(probe.get("count").asInt64 == 2)
        #expect(probe.get("first").asString == "x")
        #expect(probe.get("second").asString == "y")
    }

    @Test("Script lifecycle: renderFn, evalFn error, yielding spawnFn/poll wakeAfter, reloadCompiled failure, call/sources/withVM/fire/logs")
    func scriptLifecycleMethodsAndScheduling() throws {
        final class HookLogBox: @unchecked Sendable {
            var logs: [(LogLevel, String)] = []
            var startedCount = 0
            var lastVMID: UInt64 = 0
            var hadScriptSignal = false
        }
        let box = HookLogBox()
        let customStyle = TextStyle(size: 16, weight: 500, family: .monospace)

        final class WakerFlag: @unchecked Sendable {
            var count = 0
        }
        let wakerFlag = WakerFlag()
        let waker = Waker { wakerFlag.count += 1 }

        let opts = ScriptOptions()
            .onLog { lvl, msg in box.logs.append((lvl, msg)) }
            .text(customStyle, weights: [300, 450, 650, 800])
            .setup { host in
                host.global("HOST_CONST", value: .number(99))
                let pingSig = try host.signal("ping")
                host.global("PING_SIG", value: pingSig)
                box.hadScriptSignal = !host.scriptSignal().isNil
                #expect(!host.vm.globals.rawGet("math").isNil)
            }
            .start { vm, mod, vmID in
                box.startedCount += 1
                box.lastVMID = vmID
                let boot = mod.rawGet("onStart")
                if !boot.isNil {
                    _ = try vm.call(value: boot, args: [.number(Double(vmID))])
                }
            }

        let initialSource = Sources.single("""
        local ui = require("@rune/ui")
        local startedVMID = 0
        local calls = {}
        local pings = 0
        PING_SIG:Connect(function(v)
            pings += (v or 1)
        end)
        return {
            onStart = function(id)
                startedVMID = id
            end,
            render = function(cx)
                return ui.text("v1", { key = "r1" })
            end,
            renderCard = function(view, label, tag)
                return ui.col({
                    view:Memo(77, label, function()
                        return ui.text(label .. ":" .. tag, { weight = "medium" })
                    end),
                })
            end,
            bump = function(x)
                table.insert(calls, x)
            end,
            delayed = function()
                task.wait(0.25)
                table.insert(calls, "after-wait")
            end,
            badEval = function()
                error("eval-kaboom")
            end,
            saveHotState = function()
                error("hot-save-err")
            end,
            probe = function()
                return {
                    startedVMID = startedVMID,
                    hostConst = HOST_CONST,
                    calls = calls,
                    pings = pings,
                }
            end,
        }
        """)

        let script = Script(name: "life", sources: initialSource, options: opts)
        #expect(script.name == "life")
        #expect(script.sources.entryPath == initialSource.entryPath)
        #expect(box.startedCount == 1)
        #expect(box.lastVMID > 0)
        #expect(box.hadScriptSignal == true)
        script.setWaker(waker)

        let ranInVM = script.withVM { vm in
            vm.globals.rawGet("HOST_CONST").asInt
        }
        #expect(ranInVM == 99)

        let cx = Cx<LuauTestState>(viewport: Vec2(400, 200))
        let renderCardFn = script.module?.rawGet("renderCard") ?? .nil
        // renderFn passes surfaceID = "{prefix}{id}" and inner memo prefix "{prefix}" so memo keys match "{prefix}{key}".
        let cardEl: El<LuauTestState> = script.renderFn(cx, id: "c1", fn: renderCardFn, args: [LuauValue.string("hi"), LuauValue.number(2)])
        #expect(cardEl.keyId == "\(script.memoPrefix())c1")
        let memoNode = findElement(cardEl) { $0.keyId == "\(script.memoPrefix())77" }
        #expect(memoNode != nil)
        #expect(memoNode?.plainText == "hi:2")
        #expect(memoNode?.textStyle.family == .monospace)
        #expect(memoNode?.textStyle.size == 16)
        #expect(memoNode?.textStyle.weight == 450)

        // evalFn error logs error, throws ScriptError, and does NOT bump version.
        let versionBeforeBadEval = script.version
        let badEvalFn = script.module?.rawGet("badEval") ?? .nil
        #expect(throws: ScriptError.self) {
            _ = try script.evalFn(badEvalFn)
        }
        #expect(script.version == versionBeforeBadEval)
        #expect(box.logs.contains { $0.0 == .error && $0.1.contains("eval-kaboom") })

        // call happy, call missing, fire happy & missing
        try script.call("bump", args: [LuauData.string("direct")])
        #expect(throws: ScriptError.self) {
            try script.call("doesNotExist")
        }
        #expect(script.fire("ping", args: [LuauData.integer(4)]) == true)
        #expect(script.fire("missingSignal") == false)

        // Yielding spawnFn arms tx.wakeAfter and poll resumes it once elapsed.
        var tx = Tx()
        _ = script.poll(now: 100.0, tx: &tx)
        tx = Tx()
        let delayedFn = script.module?.rawGet("delayed") ?? .nil
        try script.spawnFn(delayedFn, tx: &tx)
        let wakeWait = tx.runtimeActions["wakeAfter"] as? Double
        #expect(wakeWait != nil && (wakeWait ?? 0) > 0.2)

        var pollEarlyTx = Tx()
        let earlyRan = script.poll(now: 100.01, tx: &pollEarlyTx)
        #expect(earlyRan == false)
        #expect(dataList((try script.query("probe")).get("calls")).compactMap(\.asString) == ["direct"])

        var pollDoneTx = Tx()
        let lateRan = script.poll(now: 101.0, tx: &pollDoneTx)
        #expect(lateRan == true)

        let p = try script.query("probe")
        #expect(p.get("startedVMID").asInt64 == Int64(box.lastVMID))
        #expect(p.get("hostConst").asInt64 == 99)
        #expect(p.get("pings").asInt64 == 4)
        #expect(dataList(p.get("calls")).compactMap(\.asString) == ["direct", "after-wait"])

        // reload failure throws, logs error, and preserves old working VM.
        let brokenSources = Sources.single("local x = (")
        #expect(throws: ScriptError.self) {
            try script.reload(brokenSources)
        }
        #expect(try script.query("probe").get("hostConst").asInt64 == 99)

        // reloadCompiled failure throws, logs error, and keeps old working VM.
        let badRuntimeCompiled = try Sources.single("error('init-fail')").compile()
        #expect(throws: ScriptError.self) {
            try script.reloadCompiled(Sources.single("error('init-fail')"), compiled: badRuntimeCompiled, compileDuration: .zero)
        }
        #expect(try script.query("probe").get("hostConst").asInt64 == 99)

        // Happy reload logs saveHotState error as .warn, logs "reloaded in ...", clears warnedMessages.
        _ = script.renderUncached(name: "render", dark: true, LuauTestState.self)
        let v2Report = try script.reload(Sources.single("""
        local ui = require("@rune/ui")
        return {
            render = function(cx)
                return ui.box({ dir = "ltr" }, { ui.text("v2") })
            end,
        }
        """))
        #expect(v2Report.compileDuration >= .zero)
        #expect(box.logs.contains { $0.0 == .warn && $0.1.contains("hot-save-err") })
        #expect(box.logs.contains { $0.0 == .info && $0.1.contains("reloaded in ") })

        // Failed script: withVM returns nil and reload card works.
        let brokenScript = Script(name: "broken", sources: Sources.single("error('start-broken')"), options: opts)
        let vmNil: Int? = brokenScript.withVM { _ in 1 }
        #expect(vmNil == nil)
        let errCard = brokenScript.renderUncached(name: "render", dark: true, LuauTestState.self)
        let errRoot = findElement(errCard) { $0.keyId == "luau-error" }
        #expect(errRoot != nil)
        let titleEl = collectTexts(errCard)
        #expect(titleEl.contains { $0.contains("Stopped drawing:") && $0.contains("start-broken") })

        // Check LuauCard.errorCard wrap (title + body wrapped; Reload button unwrapped) and LuauCard.rowError styling directly.
        let cardDirect = LuauCard.errorCard(message: "line1\nline2", palette: defaultPalette(), dark: true) { _, _ in } as El<LuauTestState>
        let wrappedTexts = findAllTexts(cardDirect)
        #expect(wrappedTexts.count == 3)
        #expect(wrappedTexts[0].textStyle.wrap == .wrap)
        #expect(wrappedTexts[1].textStyle.wrap == .wrap)

        let rowErrEl = LuauCard.rowError(message: "row boom") as El<LuauTestState>
        #expect(rowErrEl.textStyle.wrap == .ellipsis)
        #expect(rowErrEl.textStyle.family == .monospace)
        #expect(rowErrEl.layout.width == .fraction(1.0))

        // Clicking luau-reload on errorCard reloads from currentSources into healthy state.
        final class FailToggle: @unchecked Sendable { var fail = true }
        let toggle = FailToggle()
        let recOpts = ScriptOptions().setup { host in
            let fn = LuauNativeFunction(name: "shouldFail") { _, _, _ in .values([.bool(toggle.fail)]) }
            host.global("SHOULD_FAIL", value: .nativeFunction(fn))
        }
        let badRenderScript = Script(name: "rec", sources: Sources.single("""
        local ui = require("@rune/ui")
        return {
            render = function(cx)
                if SHOULD_FAIL() then error("first-render-boom") end
                return ui.text("recovered")
            end,
        }
        """), options: recOpts)
        let firstCard = badRenderScript.renderUncached(name: "render", dark: true, LuauTestState.self)
        let reloadBtn = findElement(firstCard) { $0.keyId == "luau-reload" }
        #expect(reloadBtn != nil)
        toggle.fail = false
        var clickState = LuauTestState()
        var clickTx = Tx()
        reloadBtn?.handlers.onClick?(&clickState, &clickTx)
        let secondCard = badRenderScript.renderUncached(name: "render", dark: true, LuauTestState.self)
        #expect(findElement(secondCard) { $0.plainText == "recovered" } != nil)
    }

    @Test("noteSchedule and settle: task.defer/delay inside render wake & poll, onClick sets wakeAfter")
    func noteScheduleAndSettle() throws {
        final class WakeCount: @unchecked Sendable { var n = 0 }
        let wakes = WakeCount()
        let script = Script(
            name: "sched",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local log = {}
            local first = true
            return {
                render = function(cx)
                    if first then
                        first = false
                        task.defer(function()
                            table.insert(log, "deferred")
                        end)
                        task.delay(0.15, function()
                            table.insert(log, "delayed")
                        end)
                    end
                    return ui.col({
                        ui.box({
                            key = "btn",
                            onPress = function()
                                task.delay(0.3, function()
                                    table.insert(log, "click-delay")
                                end)
                            end,
                        }),
                    })
                end,
                log = function() return log end,
            }
            """)
        )
        script.setWaker(Waker { wakes.n += 1 })
        var initTx = Tx()
        _ = script.poll(now: 50.0, tx: &initTx)
        let cx = Cx<LuauTestState>(viewport: Vec2(200, 100))
        let root = script.view(cx)
        // Render scheduled defer + delay, so waker should have been signaled by noteSchedule().
        #expect(wakes.n >= 1)

        var pollTx = Tx()
        _ = script.poll(now: 50.01, tx: &pollTx)
        let pendingWait = pollTx.runtimeActions["wakeAfter"] as? Double
        #expect(pendingWait != nil && (pendingWait ?? 0) > 0.05)
        #expect(dataList(try script.query("log")).compactMap(\.asString) == ["deferred"])

        var lateTx = Tx()
        _ = script.poll(now: 50.5, tx: &lateTx)
        #expect(dataList(try script.query("log")).compactMap(\.asString) == ["deferred", "delayed"])

        // Clicking button with task.delay sets tx.wakeAfter inside active Tx.
        let btn = findElement(root) { $0.keyId == "btn" }
        var st = LuauTestState()
        var clickTx = Tx()
        btn?.handlers.onClick?(&st, &clickTx)
        let clickWait = clickTx.runtimeActions["wakeAfter"] as? Double
        #expect(clickWait != nil && (clickWait ?? 0) > 0.2)
    }

    @Test("HostNodes: NodeArgs helpers, two-table layering, Press.attach + pressLater, onHover, key preserved")
    func hostNodesFullSurface() throws {
        final class NodeCapture: @unchecked Sendable {
            var content: String?
            var childrenCount = 0
            var gotBool = false
            var gotNum: Double?
            var gotStr: String?
            var gotFlag = false
            var gotData: LuauData?
            var gotColor: Color?
            var gotPalette: Color?
            var gotDark: Bool?
            var hadHandler = false
            var hadPressLater = false
        }
        let cap = NodeCapture()

        let probeNode = HostNode(name: "probe") { (args: NodeArgs) -> El<LuauTestState> in
            cap.content = args.content
            let kids = args.children(LuauTestState.self)
            cap.childrenCount = kids.count
            if case .bool(let b)? = args.get("flagA") { cap.gotBool = b }
            cap.gotNum = args.number("num")
            cap.gotStr = args.string("label")
            cap.gotFlag = args.flag("enabled")
            cap.gotData = args.data("meta")
            cap.gotColor = args.color("tint")
            cap.gotPalette = args.palette("bg")
            cap.gotDark = args.dark
            cap.hadHandler = args.handler("onCustom") != nil

            var root = El<LuauTestState>(direction: .column)
            for k in kids { root = root.child(k) }

            if let later = args.pressLater("onPress") {
                cap.hadPressLater = true
                root = later.attach(root, fields: [("extra", .string("from-attach"))])
            }
            if let custom = args.handler("onCustom") {
                let childBtn = El<LuauTestState>()
                    .key("custom-btn")
                    .onClick(args.onPressWith(LuauTestState.self, handler: custom, key: "custom-k", fields: [("tag", .integer(42))]))
                root = root.child(childBtn)
            }
            if let hov = args.handler("onHover") {
                root = root.onHover(args.onHover(LuauTestState.self, handler: hov))
            }
            return root
        }

        let hoverNode = HostNode(name: "hoverHelper") { (args: NodeArgs) -> El<LuauTestState> in
            var el = El<LuauTestState>(direction: .row)
            el = args.onPress(el, "onPress")
            el = args.onHover(el, "onHover")
            return el
        }

        var opts = ScriptOptions()
        opts.nodes = [probeNode, hoverNode]
        let script = Script(
            name: "host_nodes",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local events = {}
            return {
                render = function(cx)
                    return ui.col({
                        ui.probe("hello-node", {
                            key = "probe-root",
                            flagA = true,
                            num = 1,
                            label = "layer1",
                            enabled = true,
                            meta = { a = 10 },
                            tint = "#ff0000",
                            onPress = function(ev) table.insert(events, ev) end,
                            onCustom = function(ev) table.insert(events, ev) end,
                            onHover = function(ev) table.insert(events, ev) end,
                        }, {
                            num = 2,
                            label = "layer2",
                        }, {
                            ui.text("kid1"),
                        }),
                        ui.hoverHelper({
                            key = "hh",
                            onPress = function(ev) table.insert(events, ev) end,
                            onHover = function(ev) table.insert(events, ev) end,
                        }),
                    })
                end,
                events = function() return events end,
            }
            """),
            options: opts
        )

        let cx = Cx<LuauTestState>(viewport: Vec2(400, 200), systemDark: false)
        let root = script.view(cx)
        #expect(cap.content == "hello-node")
        #expect(cap.childrenCount == 1)
        #expect(cap.gotBool == true)
        #expect(cap.gotNum == 2)
        #expect(cap.gotStr == "layer2")
        #expect(cap.gotFlag == true)
        #expect(cap.gotData == .map(["a": .integer(10)]))
        #expect(cap.gotColor != nil)
        #expect(cap.gotPalette != nil)
        #expect(cap.gotDark == false)
        #expect(cap.hadHandler == true)
        #expect(cap.hadPressLater == true)

        // Crucial parity fix: unread "key" must NOT be suppressed by onPress/onHover/pressLater!
        let probeEl = findElement(root) { $0.keyId == "probe-root" }
        #expect(probeEl != nil)
        let hhEl = findElement(root) { $0.keyId == "hh" }
        #expect(hhEl != nil)

        var st = LuauTestState()
        var tx = Tx()
        let press = PointerPress(window: .zero, local: .zero, elementSize: Vec2(20, 20), mods: Mods(shift: true))
        probeEl?.handlers.onPointerUp?(&st, press, &tx)
        probeEl?.handlers.onClick?(&st, &tx)
        probeEl?.handlers.onHover?(&st, true, &tx)
        let customBtn = findElement(root) { $0.keyId == "custom-btn" }
        customBtn?.handlers.onClick?(&st, &tx)
        hhEl?.handlers.onClick?(&st, &tx)
        hhEl?.handlers.onHover?(&st, false, &tx)

        let evs = dataList(try script.query("events"))
        #expect(evs.count == 5)
        #expect(evs[0].get("key").asString == "probe-root")
        #expect(evs[0].get("extra").asString == "from-attach")
        #expect(evs[0].get("shift").asBool == true)
        #expect(evs[1].get("kind").asString == "hover")
        #expect(evs[1].get("key").asString == "probe-root")
        #expect(evs[1].get("entered").asBool == true)
        #expect(evs[2].get("key").asString == "custom-k")
        #expect(evs[2].get("tag").asInt64 == 42)
        #expect(evs[3].get("key").asString == "hh")
        #expect(evs[4].get("kind").asString == "hover")
        #expect(evs[4].get("entered").asBool == false)
    }

    @Test("virtualList: prop type errors, rowVersions selective rebuild, rowError fallback, and per-row aroundRead")
    func virtualListValidationRowVersionsAndHooks() throws {
        // 1. Type validation errors
        for badProp in [
            "gap = \"wide\"",
            "scrollY = 123",
            "estimatedRowHeight = \"tall\"",
            "rowVersions = \"bad\"",
            "rowVersions = {1, 2, {}}",
            "version = {}",
            "rowKey = 42",
            "rowError = 42",
        ] {
            let s = Script(name: "bad_vlist", sources: Sources.single("""
            local ui = require("@rune/ui")
            return {
                render = function()
                    return ui.virtualList({
                        count = 1,
                        renderRow = function(i) return ui.text("r" .. i) end,
                        \(badProp),
                    })
                end,
            }
            """))
            let el = s.renderUncached(name: "render", dark: true, LuauTestState.self)
            #expect(findElement(el) { $0.keyId == "luau-error" } != nil)
        }

        // 2. rowVersions selective rebuild + custom rowError + default LuauCard.rowError + per-row aroundRead
        final class Hooks: @unchecked Sendable { var reads = 0; var allowRead = true }
        let hooks = Hooks()
        var opts = ScriptOptions()
        opts.aroundRead = { _, run in
            hooks.reads += 1
            if hooks.allowRead { run() }
        }
        let script = Script(
            name: "vlist_rows",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local row1Build = 0
            local row2Build = 0
            local r1Ver = 1
            local r2Ver = 1
            local mode = "custom-err"
            return {
                render = function(cx)
                    return ui.virtualList({
                        key = "vl",
                        count = 2,
                        version = 1,
                        rowVersions = { r1Ver, r2Ver },
                        renderRow = function(i)
                            if i == 1 then
                                row1Build += 1
                                return ui.text("r1:" .. row1Build)
                            else
                                row2Build += 1
                                if mode == "custom-err" then error("row2-custom") end
                                if mode == "default-err" then error("row2-default") end
                                return ui.text("r2:" .. row2Build)
                            end
                        end,
                        rowError = function(i, msg)
                            if mode == "default-err" then return nil end
                            return ui.text("fallback:" .. i .. ":" .. msg)
                        end,
                    })
                end,
                bumpRow2 = function(newMode)
                    r2Ver += 1
                    mode = newMode
                end,
                builds = function() return { r1 = row1Build, r2 = row2Build } end,
            }
            """),
            options: opts
        )

        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let el1 = script.view(cx)
        // Two mounted rows -> aroundRead called once per row (2).
        #expect(hooks.reads == 2)
        let texts1 = collectTexts(el1)
        #expect(texts1.contains("r1:1"))
        #expect(texts1.contains { $0.contains("fallback:2:") && $0.contains("row2-custom") })

        // Bump only row 2 version -> row 1 memo skips rebuild, row 2 falls back to LuauCard.rowError when rowError returns nil.
        try script.call("bumpRow2", args: [.string("default-err")])
        let el2 = script.view(cx)
        let b2 = try script.query("builds")
        #expect(b2.get("r1").asInt64 == 1)
        #expect(b2.get("r2").asInt64 == 2)
        let row2Err = findElement(el2) { ($0.plainText ?? "").contains("row2-default") }
        #expect(row2Err != nil)
        #expect(row2Err?.textStyle.wrap == .ellipsis)
        #expect(row2Err?.textStyle.family == .monospace)

        // When aroundRead declines to call run(), row renders empty element without rebuilding row.
        try script.call("bumpRow2", args: [.string("ok")])
        hooks.allowRead = false
        let el3 = script.view(cx)
        let b3 = try script.query("builds")
        #expect(b3.get("r2").asInt64 == 2)
        #expect(!collectTexts(el3).contains("r1:1"))
    }

    @Test("ui.each memo/rebuild, view:Memo error paths & pcall recovery, stale & nested table child errors")
    func eachMemoAndChildrenErrors() throws {
        // 1. ui.each happy path (string field key & fn key) + selective rebuild
        let eachScript = Script(
            name: "each_happy",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local builds = { a = 0, b = 0 }
            local items = { { id = "a", v = 1 }, { id = "b", v = 1 } }
            return {
                render = function()
                    return ui.col({
                        ui.col({}, ui.each(items, "id", "v", function(it)
                            builds[it.id] += 1
                            return ui.text(it.id .. ":" .. builds[it.id])
                        end)),
                        ui.col({}, ui.each(items, function(it) return "fn-" .. it.id end, function(it) return it.v end, function(it)
                            return ui.text("fn-" .. it.id .. "-" .. it.v)
                        end)),
                    })
                end,
                bumpB = function() items[2].v += 1 end,
                builds = function() return builds end,
            }
            """)
        )
        let cx = Cx<LuauTestState>(viewport: Vec2(300, 200))
        let e1 = eachScript.view(cx)
        #expect(collectTexts(e1).contains("a:1"))
        #expect(collectTexts(e1).contains("b:1"))
        #expect(collectTexts(e1).contains("fn-b-1"))
        try eachScript.call("bumpB")
        let e2 = eachScript.view(cx)
        let b = try eachScript.query("builds")
        #expect(b.get("a").asInt64 == 1)
        #expect(b.get("b").asInt64 == 2)
        #expect(collectTexts(e2).contains("fn-b-2"))

        // 2. Stale element saved across renders + nested table child error
        let staleScript = Script(
            name: "stale_and_nested",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local saved
            return {
                renderStale = function()
                    if not saved then
                        saved = ui.text("saved")
                    end
                    return ui.col({ saved })
                end,
                renderNestedTable = function()
                    return ui.col({ { ui.text("nested") } })
                end,
            }
            """)
        )
        _ = staleScript.renderUncached(name: "renderStale", dark: true, LuauTestState.self)
        let staleSecond = staleScript.renderUncached(name: "renderStale", dark: true, LuauTestState.self)
        #expect(collectTexts(staleSecond).contains { $0.contains("elements cannot be saved across renders") })

        let nestedEl = staleScript.renderUncached(name: "renderNestedTable", dark: true, LuauTestState.self)
        #expect(collectTexts(nestedEl).contains { $0.contains("child 1 is a table, not a ui node") })

        // 3. view:Memo error paths & pcall recovery
        let memoScript = Script(
            name: "memo_errs",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            local shouldFail = true
            return {
                missingArgs = function(view) return view:Memo("k") end,
                badKey = function(view) return view:Memo({}, 1, function() return ui.text("x") end) end,
                badBuild = function(view) return view:Memo("k", 1, "not-a-fn") end,
                pcallRecover = function(view)
                    local ok = pcall(function()
                        return view:Memo("r", 1, function()
                            if shouldFail then error("inner-memo-fail") end
                            return ui.text("ok")
                        end)
                    end)
                    if ok then return ui.text("recovered") end
                    shouldFail = false
                    return view:Memo("r", 2, function() return ui.text("after-pcall") end)
                end,
            }
            """)
        )
        for fnName in ["missingArgs", "badKey", "badBuild"] {
            let errEl = memoScript.renderUncached(name: fnName, dark: true, LuauTestState.self)
            #expect(findElement(errEl) { $0.keyId == "luau-error" } != nil)
        }
        let recEl = memoScript.surface(cx, name: "pcallRecover")
        #expect(collectTexts(recEl).contains("after-pcall"))
    }

    @Test("Layered Luau props finalize in Rust order across mutable and frozen styles")
    func layeredPropsFinalizeAfterHandlersAndOverrides() throws {
        let accent = Color.srgb(0.3, 0.4, 0.5)
        let fill = Color.srgb(0.2, 0.3, 0.1)
        let script = Script(name: "layers", sources: Sources.single("""
            local ui = require("@rune/ui")
            local function callback() end
            local style = {center = true, disabled = true, selected = true, scrollX = true,
                           corners = table.freeze({1, "2", 3, 4}), pad = 9}
            local frozen = table.freeze(table.clone(style))
            local function box(base, key)
                return ui.box(base, {key = key, pl = 2, align = "end", justify = "end",
                    radius = 20, fill = "fill", role = "group", onPress = callback, onHover = callback,
                    onMiddlePress = callback, focusable = true, scrollX = false, scrollY = true})
            end
            return {render = function()
                return ui.col({
                    box(style, "mutable"), box(frozen, "frozen"),
                    ui.box(frozen, {key = "reset", fill = "fill", center = false, selected = false,
                        disabled = false, align = "end", onPress = callback, role = "group"}),
                    ui.text("truncate", {key = "text", truncate = true}),
                    ui.text("wrap", {truncate = true, noWrap = true}, {key = "wrap", wrap = true}),
                    ui.box({key = "list", role = "list"}), ui.box({key = "status", role = "status"}),
                })
            end}
            """), options: ScriptOptions().palette { name, dark in
                switch name {
                case "selected": return accent
                case "fill": return fill
                default: return defaultPalette()(name, dark)
                }
            })
        let cx = Cx<LuauTestState>(viewport: Vec2(320, 240))
        for _ in 0..<2 {
            let root = script.view(cx)
            for key in ["mutable", "frozen"] {
                let box = try #require(findElement(root) { $0.keyId == key })
                #expect(box.layout.alignItems == .center)
                #expect(box.layout.justifyContent == .center)
                #expect(box.layout.padding.left == 2 && box.layout.padding.top == 9)
                #expect(box.corners == Corners(1, 0, 3, 4))
                #expect(box.background == accent && box.isFocusSelected)
                #expect(box.layout.scrollAxes == .both)
                #expect(box.a11yDisabled && !box.focusable)
                #expect(box.handlers.onHover != nil)
                #expect(box.handlers.onClick == nil && box.handlers.onMiddlePress == nil)
            }
            let reset = try #require(findElement(root) { $0.keyId == "reset" })
            #expect(reset.background == fill && !reset.isFocusSelected)
            #expect(!reset.a11yDisabled && reset.focusable)
            #expect(reset.layout.alignItems == .end)
            #expect(reset.role == .group && reset.handlers.onClick != nil)
            let text = try #require(findElement(root) { $0.keyId == "text" })
            #expect(text.textStyle.wrap == .ellipsis && text.layout.flexShrink == 1)
            #expect(findElement(root) { $0.keyId == "wrap" }?.textStyle.wrap == .wrap)
            #expect(findElement(root) { $0.keyId == "status" }?.role == .status)
            #expect(findElement(root) { $0.keyId == "list" }?.role == .list)
        }
    }

    @Test("Props, defaultPalette light/dark tokens, shadow reversal, dir, fadeOut, hoverTransition")
    func propsPaletteShadowsAndTextDirection() throws {
        // 1. Default palette tokens (light & dark)
        let pal = defaultPalette()
        let tokenNames = [
            "bg", "card", "card-border", "text", "text-secondary",
            "separator", "hover", "press", "control-off", "control-track", "indicator",
        ]
        for tok in tokenNames {
            let light = pal(tok, false)
            let dark = pal(tok, true)
            #expect(light != nil)
            #expect(dark != nil)
            if tok != "indicator" {
                #expect(light != dark)
            }
        }
        #expect(pal("selected", true) == nil)
        #expect(pal("not-a-token", true) == nil)

        // 2. Custom palette, reversed shadow order, and exhaustive prop checks
        let opts = ScriptOptions()
            .palette { name, dark in
                if name == "selected" { return .srgb(0.1, 0.2, 0.3) }
                if name == "accent" { return dark ? .srgb(0.9, 0.1, 0.1) : .srgb(0.1, 0.1, 0.9) }
                return defaultPalette()(name, dark)
            }
            .shadows { name, _ in
                guard name == "raised" else { return nil }
                return [
                    Shadow(x: 0, y: 1, blur: 2, spread: 0, color: .srgb(1, 0, 0)),
                    Shadow(x: 0, y: 8, blur: 12, spread: 0, color: .srgb(0, 0, 1)),
                ]
            }

        let script = Script(
            name: "props_full",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            return {
                render = function()
                    return ui.col({
                        ui.col({
                            key = "root",
                        m = 4, mx = 6, mt = 8,
                        pad = 10, pl = 2,
                        minW = 10, maxW = 200, minH = 5, maxH = 100,
                        grow = 2, shrink = true,
                        opacity = 0.5,
                        border = "accent", borderWidth = 3,
                        corners = { 6, 6, 6, 6 },
                        clip = true,
                        pin = { top = 1, right = 2, bottom = 3, left = 4 },
                        shadow = "raised",
                        align = "center", justify = "between", center = true,
                        hoverGroup = true, hoverGroupColor = "accent",
                        helpSide = "right", help = "tip",
                        hoverTransition = "instant",
                        selected = true, focusable = true,
                    }, {
                        ui.text("rtl", {
                            key = "t1",
                            dir = "rtl",
                            fadeOut = true,
                            lineHeight = 20,
                            tracking = 1.5,
                            mono = true,
                            textAlign = "end",
                            revealOnHover = true,
                        }),
                        ui.col({ key = "scx", dir = "rtl", scrollX = true, disabled = true }),
                        ui.col({ key = "scxy", scrollX = true, scrollY = true, stickBottom = true }),
                    }),
                    })
                end,
            }
            """),
            options: opts
        )

        let cx = Cx<LuauTestState>(viewport: Vec2(400, 300), systemDark: true)
        let root = script.view(cx)
        let el = findElement(root) { $0.keyId == "root" }!
        #expect(el.opacity == 0.5)
        #expect(el.borderWidth == 3)
        #expect(el.isHoverGroup == true)
        #expect(el.groupColor != nil)
        #expect(el.helpSide == .right)
        #expect(el.isFocusSelected == true)
        #expect(el.focusable == true)
        let scx = findElement(root) { $0.keyId == "scx" }!
        #expect(scx.a11yDisabled == true)
        #expect(scx.explicitDir == .rtl)
        #expect(el.hoverMotionSpec?.enter == Anim<Float>.instant)
        #expect(el.hoverMotionSpec?.exit == Anim<Float>.instant)
        #expect(el.layout.flexGrow == 2)
        #expect(el.layout.flexShrink == 1)
        #expect(el.layout.padding.top == 10)
        #expect(el.layout.padding.left == 2)
        #expect(el.layout.margin.top == 8)
        #expect(el.layout.margin.left == 6)
        // Shadows reversed from CSS order (blur 2, blur 12 -> blur 12, blur 2)
        #expect(el.shadows.map(\.blur) == [12, 2])

        let t1 = findElement(root) { $0.keyId == "t1" }!
        #expect(t1.explicitDir == .rtl)
        #expect(t1.textStyle.direction == .rtl)
        #expect(t1.isTruncateFadeEnabled == true)
        #expect(t1.truncateFadeEm == 1.5)
        #expect(t1.textStyle.lineHeight == 20)
        #expect(t1.textStyle.letterSpacing == 1.5)
        #expect(t1.textStyle.family == .monospace)
        #expect(t1.textStyle.align == .trailing)
        #expect(t1.groupOpacity?.rest == 0)
        #expect(t1.groupOpacity?.hovered == 1)

        // All three El APIs are wired without warnings
        let logs = script.log
        #expect(!logs.contains { $0.message.contains("fadeOut") })
        #expect(!logs.contains { $0.message.contains("dir only applies") })
        #expect(!logs.contains { $0.message.contains("hoverTransition") })
    }
}

private func findAllTexts<S>(_ root: El<S>) -> [El<S>] {
    var out: [El<S>] = []
    if root.plainText != nil { out.append(root) }
    for c in root.children {
        out.append(contentsOf: findAllTexts(c))
    }
    return out
}
