import Foundation
import Testing
@testable import Rune
@testable import RuneLuau

@Suite("RuneLuau Tests")
struct RuneLuauTests {
    private struct DummyState {}

    @Test("Luau syntax: types, interpolation, if-expr, compound ops, closures, generalized iteration")
    func luauSyntax() throws {
        let vm = LuauVM()
        let result = try vm.eval("""
        --!strict
        export type Item = { id: number, name: string, done: boolean }
        type Pair<A, B> = { first: A, second: B }

        local function makeCounter(start: number): () -> number
            local count = start
            return function(): number
                count += 1
                return count
            end
        end

        local c = makeCounter(10)
        local a = c()
        local b = c()

        local x: number = 17
        local q = x // 5
        local tag = if q == 3 then "three" else "other"
        local msg = `a={a}, b={b}, tag={tag}`

        local sum = 0
        local list = { 10, 20, 30, 40 }
        for i, v in list do
            if i == 2 then
                continue
            end
            sum += v
        end

        return msg, sum, q
        """)
        #expect(result.count == 3)
        #expect(result[0].asString == "a=11, b=12, tag=three")
        #expect(result[1].asInt == 80)
        #expect(result[2].asInt == 3)
    }

    @Test("Metatables and newproxy")
    func metatablesAndProxy() throws {
        let vm = LuauVM()
        let result = try vm.eval("""
        local mt = {
            __add = function(a, b) return setmetatable({ v = a.v + b.v }, getmetatable(a)) end,
            __tostring = function(a) return "Box(" .. tostring(a.v) .. ")" end,
            __call = function(a, mult) return a.v * mult end,
            __len = function(a) return a.v end,
        }
        local b1 = setmetatable({ v = 4 }, mt)
        local b2 = setmetatable({ v = 6 }, mt)
        local b3 = b1 + b2

        local p = newproxy(true)
        local pmt = getmetatable(p)
        pmt.__type = "CustomProxy"
        return tostring(b3), b3(3), #b3, typeof(p)
        """)
        #expect(result[0].asString == "Box(10)")
        #expect(result[1].asInt == 30)
        #expect(result[2].asInt == 10)
        #expect(result[3].asString == "CustomProxy")
    }

    @Test("Stdlib: math, string patterns, table, bit32, utf8, coroutine, pcall")
    func stdlib() throws {
        let vm = LuauVM()
        let result = try vm.eval("""
        local s = "hello 42 world 99"
        local firstNum = string.match(s, "%d+")
        local replaced, n = string.gsub(s, "%d+", function(d) return tostring(tonumber(d) * 2) end)
        local fmt = string.format("%03d", 7)
        local parts = string.split("a,b,c", ",")

        local t = table.create(3, 5)
        table.insert(t, 9)
        table.sort(t, function(x, y) return x > y end)
        local frozen = table.freeze({ x = 1 })
        local okFreeze, _ = pcall(function() frozen.x = 2 end)

        local b = bit32.bor(bit32.lshift(1, 4), 3)
        local ulen = utf8.len("héllo")

        local co = coroutine.create(function(x)
            local y = coroutine.yield(x + 1)
            return y * 10
        end)
        local ok1, v1 = coroutine.resume(co, 5)
        local st = coroutine.status(co)
        local ok2, v2 = coroutine.resume(co, 4)

        return firstNum, replaced, n, fmt, #parts, t[1], table.isfrozen(frozen), okFreeze, b, ulen, ok1, v1, st, ok2, v2
        """)
        #expect(result[0].asString == "42")
        #expect(result[1].asString == "hello 84 world 198")
        #expect(result[2].asInt == 2)
        #expect(result[3].asString == "007")
        #expect(result[4].asInt == 3)
        #expect(result[5].asInt == 9)
        #expect(result[6].asBool == true)
        #expect(result[7].asBool == false)
        #expect(result[8].asInt == 19)
        #expect(result[9].asInt == 5)
        #expect(result[10].asBool == true)
        #expect(result[11].asInt == 6)
        #expect(result[12].asString == "suspended")
        #expect(result[13].asBool == true)
        #expect(result[14].asInt == 40)
    }

    @Test("Watchdog terminates infinite loops cleanly and VM recovers")
    func watchdogTimeout() throws {
        let sources = Sources.single("""
        return {
            spin = function() while true do end end,
            ok = function() return 42 end,
        }
        """)
        let options = ScriptOptions().timeLimit(.milliseconds(40))
        let script = Script(name: "spin", sources: sources, options: options)

        var caught: ScriptError?
        do {
            _ = try script.query("spin")
        } catch let err as ScriptError {
            caught = err
        }
        #expect(caught?.kind == .timeout)
        let after = try script.query("ok")
        #expect(after.asInt64 == 42)
    }

    @Test("LuauData decode preserves integer vs float fidelity")
    func dataDecode() throws {
        struct Values: Decodable, Equatable {
            let small: Int64
            let big: Int64
            let half: Double
        }
        let script = Script(
            name: "nums",
            sources: Sources.single("return { values = function() return { small = 3, big = 2^40, half = 2.5 } end }")
        )
        let data = try script.query("values")
        #expect(data.get("small").asInt64 == 3)
        #expect(data.get("big").asInt64 == (1 << 40))
        #expect(data.get("half").asDouble == 2.5)
        let decoded = try data.decode(Values.self)
        #expect(decoded == Values(small: 3, big: 1 << 40, half: 2.5))
    }

    @Test("Require rules: @self, relative, .luaurc aliases, and cycle detection")
    func requireRulesAndCycle() throws {
        let sources = Sources()
            .with("init.luau", """
            local row = require("@self/views/row")
            local escaped = pcall(require, "./views/row")
            return { probe = function() return row .. "|" .. tostring(escaped) end }
            """)
            .with("views/row.luau", "return 'row+' .. require('./util') .. '+' .. require('@lib/util')")
            .with("views/util.luau", "return 'util'")
            .with(".luaurc", #"{ "aliases": { "lib": "./views" } }"#)

        let script = Script(name: "req", sources: sources)
        let got = try script.query("probe")
        #expect(got.asString == "row+util+util|false")

        let cyclic = Sources()
            .with("init.luau", "return require('@self/a')")
            .with("a.luau", "return require('./b')")
            .with("b.luau", "return require('./a')")
        let cycleScript = Script(name: "cycle", sources: cyclic)
        #expect(cycleScript.error?.message.contains("require cycle: init.luau -> a.luau -> b.luau -> a.luau") == true)
    }

    @Test("prelude.luau task scheduler, @rune/signal, and host async function")
    func taskAndSignals() throws {
        let options = ScriptOptions().setup { host in
            let sig = try host.signal("changed")
            let doubleFn = try host.asyncFunction("double") { args, completer in
                let n = args.first?.coercedNumber ?? 0
                completer.complete(.number(n * 2))
            }
            let mod = LuauTable()
            mod.rawSet("changed", value: sig)
            mod.rawSet("double", value: doubleFn)
            host.registerModule("@host/test", value: .table(mod))
        }

        let script = Script(name: "tasks", sources: Sources.single("""
        local host = require("@host/test")
        local sig = require("@rune/signal").new()
        local log = {}

        host.changed:Connect(function(v)
            local doubled = host.double(v)
            table.insert(log, doubled)
        end)

        sig:Connect(function(n)
            table.insert(log, n)
        end)

        task.spawn(function()
            task.wait(0.05)
            sig:Fire(99)
        end)

        return {
            getLog = function() return log end,
        }
        """), options: options)

        script.fire("changed", args: [.integer(21)])
        var tx = Tx()
        _ = script.poll(now: 0.01, tx: &tx) // completes async double
        _ = script.poll(now: 0.06, tx: &tx) // wakes task.wait(0.05) -> fires sig(99)

        let log = try script.query("getLog")
        #expect(log == .list([.integer(42), .integer(99)]))
    }

    @Test("UI bridge renders El tree, handles onPress mutation, and hot reloads")
    func uiBridgeAndHotReload() throws {
        let sources = Sources()
            .with("init.luau", """
            local ui = require("@rune/ui")
            local rows = require("@self/rows")
            local count = 0
            return {
                render = function(view)
                    return ui.col({ key = "root", pad = 16, gap = 8, fill = "bg" }, {
                        view:Memo("hdr", count, function()
                            return ui.text(`Count: {count}`, { key = "count-text", size = 14 })
                        end),
                        ui.row({
                            key = "inc",
                            px = 10,
                            py = 4,
                            radius = 6,
                            fill = "control-off",
                            onPress = function()
                                count += 1
                            end,
                        }, { "Increment" }),
                        rows.badge(count),
                    })
                end,
                saveHotState = function() return { count = count } end,
                loadHotState = function(s) count = s.count or 0 end,
            }
            """)
            .with("rows.luau", """
            local ui = require("@rune/ui")
            return {
                badge = function(n: number)
                    return ui.box({ key = "badge", fill = ui.hex("#009fff"), radius = 4 }, {
                        ui.text(`B:{n}`, { size = 11 }),
                    })
                end,
            }
            """)

        let script = Script(name: "panel", sources: sources)
        let cx = Cx<DummyState>(viewport: Vec2(720, 640))
        let el1 = script.view(cx)
        #expect(el1.keyId == "luau:panel:render")

        // Simulate pressing the "inc" button
        func findButton(_ el: El<DummyState>, key: String) -> El<DummyState>? {
            if el.keyId == key { return el }
            for c in el.children {
                if let found = findButton(c, key: key) { return found }
            }
            return nil
        }

        let btn = findButton(el1, key: "inc")
        #expect(btn?.handlers.onClick != nil)
        var dummy = DummyState()
        var tx = Tx()
        btn?.handlers.onClick?(&dummy, &tx)

        // Hot reload should preserve count = 1
        _ = try script.reload(sources)
        let el2 = script.renderUncached(name: "render", dark: true, DummyState.self)
        let txt = findButton(el2, key: "count-text")
        #expect(txt?.plainText == "Count: 1")
    }

    @Test("Render error produces error card and logs error instead of crashing")
    func renderErrorCard() {
        let script = Script(
            name: "broken",
            sources: Sources.single("""
            local ui = require("@rune/ui")
            return function()
                local t = nil
                return ui.text(t.field)
            end
            """)
        )
        let el = script.renderUncached(name: "render", dark: true, DummyState.self)
        #expect(el.keyId == "luau-error")
        #expect(script.log.contains(where: { $0.level == .error && $0.message.contains("attempt to index nil") }))
    }
}
