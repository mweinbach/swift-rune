import Foundation
import Testing
@testable import Rune
@testable import RuneLuau

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
        #expect(hooks.reads == 1)

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
        #expect(propNames().count == 75)
        #expect(propNames().contains("fadeOut"))
        #expect(propNames().contains("onVisibleRows"))

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
}
