import Foundation
import Rune
import RuneLuau

/// Parity port of `examples/luau-panel` (`lib.rs`, `bench.rs`, `checks.rs`, `bin/bench.rs`):
/// Headless Luau performance gates and behavior checks on the 1,000-row Luau panel.
@main
public enum RuneLuauBenchApp {
    public enum Scale: Sendable, Equatable {
        case native
        case web
        case smoke
    }

    public struct Stat: Sendable, Equatable {
        public let n: Int
        public let mean: Double
        public let p50: Double
        public let p99: Double
        public let max: Double

        public static func of(_ rawSamples: [Double]) -> Stat {
            guard !rawSamples.isEmpty else {
                return Stat(n: 0, mean: 0, p50: 0, p99: 0, max: 0)
            }
            let samples = rawSamples.sorted()
            let n = samples.count
            func at(_ q: Double) -> Double {
                samples[Int((Double(n - 1) * q).rounded())]
            }
            return Stat(
                n: n,
                mean: samples.reduce(0, +) / Double(n),
                p50: at(0.5),
                p99: at(0.99),
                max: samples[n - 1]
            )
        }

        public func json() -> String {
            String(
                format: "{\"n\":%d,\"mean_us\":%.3f,\"p50_us\":%.3f,\"p99_us\":%.3f,\"max_us\":%.3f}",
                n, mean, p50, p99, max
            )
        }
    }

    public struct Check: Sendable, Equatable {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public struct Report: Sendable {
        public let nativeCode: Bool
        public let idle: (frames: Int, framesAsked: Int, vmCalls: UInt64)
        public let memoHit: (stat: Stat, vmCalls: UInt64)
        public let rebuild20: Stat
        public let scroll: (script: Stat, frame: Stat, rowsBuilt: UInt64)
        public let reload: (total: Stat, compile: Stat, swap: Stat, stateKept: Bool)
        public let checks: [Check]

        public func json() -> String {
            let checksJSON = checks.map { c in
                let name = Self.jsonEscape(c.name)
                let detail = Self.jsonEscape(c.detail)
                return "{\"name\":\"\(name)\",\"ok\":\(c.ok),\"detail\":\"\(detail)\"}"
            }.joined(separator: ",")
            return "{" +
                "\"native_code\":\(nativeCode)," +
                "\"idle\":{\"frames\":\(idle.frames),\"frames_asked\":\(idle.framesAsked),\"vm_calls\":\(idle.vmCalls)}," +
                "\"memo_hit\":{\"view\":\(memoHit.stat.json()),\"vm_calls\":\(memoHit.vmCalls)}," +
                "\"rebuild20\":\(rebuild20.json())," +
                "\"rebuild20_thread_time\":null," +
                "\"scroll\":{\"script_per_frame\":\(scroll.script.json()),\"frame\":\(scroll.frame.json()),\"rows_built\":\(scroll.rowsBuilt)}," +
                "\"reload\":{\"total\":\(reload.total.json()),\"compile\":\(reload.compile.json()),\"swap\":\(reload.swap.json()),\"state_kept\":\(reload.stateKept)}," +
                "\"checks\":[\(checksJSON)]" +
                "}"
        }

        public func formatted() -> String {
            func row(_ name: String, _ s: Stat, _ gate: String) -> String {
                String(
                    format: "%-34@ n=%-5d mean %9.2f µs  p50 %9.2f  p99 %9.2f  max %9.2f   gate %@",
                    name as NSString, s.n, s.mean, s.p50, s.p99, s.max, gate as NSString
                )
            }
            var lines: [String] = []
            lines.append("Luau \(nativeCode ? "native code (luau-jit)" : "interpreter")")
            lines.append("idle: \(idle.frames) frames polled, \(idle.framesAsked) asked for a frame, \(idle.vmCalls) VM calls (gate: 0)")
            lines.append("\(row("memo hit (Script::view)", memoHit.stat, "≤ 5 µs"))  VM calls \(memoHit.vmCalls)")
            lines.append(row("20-row panel rebuild", rebuild20, "≤ 120 µs"))
            lines.append(row("scroll frame, script time", scroll.script, "≤ 300 µs"))
            lines.append("\(row("scroll frame, whole frame", scroll.frame, "—"))  rows built \(scroll.rowsBuilt)")
            lines.append(row("hot reload, compile + swap", reload.total, "≤ 5,000 µs"))
            lines.append(row("hot reload, compile", reload.compile, "—"))
            lines.append("\(row("hot reload, swap", reload.swap, "—"))  state kept \(reload.stateKept)")
            for c in checks {
                lines.append(String(format: "check %-24@ %@  %@", c.name as NSString, (c.ok ? "ok  " : "FAIL") as NSString, c.detail as NSString))
            }
            return lines.joined(separator: "\n")
        }

        private static func jsonEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
    }

    public final class ViewCounter: @unchecked Sendable {
        public var viewCalls: UInt64 = 0
        public var viewTimeUs: Double = 0
    }

    public struct PanelState: @unchecked Sendable {
        public var script: Script
        public var surfaceName: String = "render"
        public var hostTicks: UInt64 = 0
        public let counter = ViewCounter()

        public init(script: Script) {
            self.script = script
        }
    }

    public static let size = Vec2(720, 640)
    public static let dt: Double = 1.0 / 120.0

    public static func embeddedSources() -> Sources {
        Sources()
            .with("init.luau", initLuauSource)
            .with("rows.luau", rowsLuauSource)
    }

    public static func view(_ s: PanelState, _ cx: inout Cx<PanelState>) -> El<PanelState> {
        let before = s.script.metrics.vmCalls
        let t0 = ContinuousClock.now
        let panel: El<PanelState> = s.surfaceName == "render"
            ? s.script.view(cx)
            : s.script.surface(cx, name: s.surfaceName)
        let elapsed = t0.duration(to: .now)
        s.counter.viewTimeUs = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
        s.counter.viewCalls = s.script.metrics.vmCalls - before
        return col().sizeFull().child(panel)
    }

    private static func makeSettledRuntime() -> (Runtime<PanelState>, Double) {
        let rt = Runtime(
            state: PanelState(script: Script(name: "panel", sources: embeddedSources())),
            viewport: size,
            pixelScale: 1.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        _ = rt.frame(at: now)
        for _ in 0..<600 {
            now += dt
            let stale = rt.updateIf(at: now) { s, tx in s.script.poll(now: now, tx: &tx) }
            _ = rt.frame(at: now)
            if !rt.isAnimating && !stale { break }
        }
        return (rt, now)
    }

    private static func us(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    public static func run(scale: Scale = .native) -> Report {
        let n: Int
        let idleFrames: Int
        let scrollFrames: Int
        let reloadN: Int
        switch scale {
        case .native:
            n = 1000
            idleFrames = 1200
            scrollFrames = 360
            reloadN = 20
        case .web:
            n = 300
            idleFrames = 1200
            scrollFrames = 360
            reloadN = 10
        case .smoke:
            n = 25
            idleFrames = 30
            scrollFrames = 24
            reloadN = 3
        }
        return Report(
            nativeCode: false,
            idle: benchIdle(frames: idleFrames),
            memoHit: benchMemoHit(n: n),
            rebuild20: benchRebuild20(n: n),
            scroll: benchScroll(frames: scrollFrames),
            reload: benchReload(n: reloadN),
            checks: runChecks()
        )
    }

    private static func benchIdle(frames: Int) -> (Int, Int, UInt64) {
        let (rt, startNow) = makeSettledRuntime()
        var now = startNow
        let before = rt.state.script.metrics.vmCalls
        var asked = 0
        for _ in 0..<frames {
            now += dt
            let stale = rt.updateIf(at: now) { s, tx in s.script.poll(now: now, tx: &tx) }
            _ = rt.frame(at: now)
            if rt.isAnimating || stale {
                asked += 1
            }
        }
        return (frames, asked, rt.state.script.metrics.vmCalls - before)
    }

    private static func benchMemoHit(n: Int) -> (Stat, UInt64) {
        let (rt, startNow) = makeSettledRuntime()
        var now = startNow
        var calls: UInt64 = 0
        var samples: [Double] = []
        samples.reserveCapacity(n)
        for _ in 0..<n {
            now += dt
            rt.update(at: now) { s, _ in s.hostTicks += 1 }
            _ = rt.frame(at: now)
            samples.append(rt.state.counter.viewTimeUs)
            calls += rt.state.counter.viewCalls
        }
        return (Stat.of(samples), calls)
    }

    private static func benchRebuild20(n: Int) -> Stat {
        let script = Script(name: "panel20", sources: embeddedSources())
        for _ in 0..<min(50, n) {
            _ = script.renderUncached(name: "panel20", dark: true, PanelState.self)
        }
        var wall: [Double] = []
        wall.reserveCapacity(n)
        for _ in 0..<n {
            let t0 = ContinuousClock.now
            _ = script.renderUncached(name: "panel20", dark: true, PanelState.self)
            wall.append(us(t0.duration(to: .now)))
        }
        return Stat.of(wall)
    }

    private static func benchScroll(frames: Int) -> (Stat, Stat, UInt64) {
        let (rt, startNow) = makeSettledRuntime()
        var now = startNow
        let rowsBefore = rt.state.script.metrics.rows
        var scriptSamples: [Double] = []
        var frameSamples: [Double] = []
        scriptSamples.reserveCapacity(frames)
        frameSamples.reserveCapacity(frames)
        for _ in 0..<frames {
            now += dt
            let m = rt.state.script.metrics
            let t0 = ContinuousClock.now
            rt.wheel(WheelEvent(dy: -40), at: Vec2(360, 400), now: now)
            _ = rt.frame(at: now)
            frameSamples.append(us(t0.duration(to: .now)))
            let vmDelta = rt.state.script.metrics.vmTime - m.vmTime
            scriptSamples.append(us(vmDelta))
        }
        return (Stat.of(scriptSamples), Stat.of(frameSamples), rt.state.script.metrics.rows - rowsBefore)
    }

    private static func benchReload(n: Int) -> (Stat, Stat, Stat, Bool) {
        let base = embeddedSources()
        let script = Script(name: "panel", sources: base)
        try? script.call("select", args: [.number(7)])
        let initSrc = base.get("init.luau") ?? ""
        var total: [Double] = []
        var compile: [Double] = []
        var swap: [Double] = []
        var kept = true
        for i in 0..<n {
            let edited = base.with("init.luau", "\(initSrc)\n-- edit \(i)\n")
            do {
                let r = try script.reload(edited)
                let cUs = us(r.compileDuration)
                let sUs = us(r.swapDuration)
                total.append(cUs + sUs)
                compile.append(cUs)
                swap.append(sUs)
            } catch {
                kept = false
            }
            let selected = (try? script.query("selected"))?.asDouble
            kept = kept && (selected == 7.0)
        }
        return (Stat.of(total), Stat.of(compile), Stat.of(swap), kept)
    }

    public static func runChecks() -> [Check] {
        [
            checkWatchdog(),
            checkRenderError(),
            checkRequireRules(),
            checkRequireCycle(),
            checkNumbers(),
            checkHostSignalAndAsync(),
        ]
    }

    private static func checkWatchdog() -> Check {
        let script = Script(
            name: "spin",
            sources: Sources.single("return { spin = function() while true do end end, ok = function() return 1 end }")
        )
        let t0 = ContinuousClock.now
        var err: ScriptError?
        do {
            _ = try script.query("spin")
        } catch let se as ScriptError {
            err = se
        } catch {
            err = ScriptError(kind: .runtime, message: error.localizedDescription)
        }
        let tookMs = us(t0.duration(to: .now)) / 1000.0
        let still = (try? script.query("ok"))?.asInt64
        let ok = err?.kind == .timeout && tookMs < 260.0 && still == 1
        return Check(
            name: "watchdog",
            ok: ok,
            detail: String(format: "stopped after %.1f ms (%@); the next call returned %@", tookMs, "\(err?.kind.rawValue ?? "none")", "\(still.map(String.init) ?? "nil")")
        )
    }

    private static func checkRenderError() -> Check {
        let script = Script(
            name: "broken",
            sources: Sources.single("local ui = require('@rune/ui')\nreturn function() local t = nil; return ui.text(t.field) end")
        )
        _ = script.renderUncached(name: "render", dark: true, PanelState.self)
        let logged = script.log.contains { $0.message.contains("attempt to index nil") }
        let firstLine = script.log.last?.message.split(separator: "\n").first.map(String.init) ?? ""
        return Check(name: "render error", ok: logged, detail: firstLine)
    }

    private static func checkRequireRules() -> Check {
        let sources = Sources()
            .with("init.luau", "local row = require('@self/views/row')\nlocal escaped = pcall(require, './views/row')\nreturn { probe = function() return row .. '|' .. tostring(escaped) end }")
            .with("views/row.luau", "return 'row+' .. require('./util') .. '+' .. require('@lib/util')")
            .with("views/util.luau", "return 'util'")
            .with(".luaurc", "{ \"aliases\": { \"lib\": \"./views\" } }")
        let script = Script(name: "req", sources: sources)
        let got: String
        do {
            got = try script.query("probe").asString ?? ""
        } catch {
            got = error.localizedDescription
        }
        return Check(name: "require", ok: got == "row+util+util|false", detail: got)
    }

    private static func checkRequireCycle() -> Check {
        let sources = Sources()
            .with("init.luau", "return require('@self/a')")
            .with("a.luau", "return require('./b')")
            .with("b.luau", "return require('./a')")
        let script = Script(name: "cycle", sources: sources)
        let msg = script.error?.message ?? ""
        let ok = msg.contains("require cycle: init.luau -> a.luau -> b.luau -> a.luau")
        let line = msg.split(separator: "\n").first.map(String.init) ?? ""
        return Check(name: "require cycle", ok: ok, detail: line)
    }

    private static func checkNumbers() -> Check {
        struct Values: Decodable, Equatable {
            let small: Int64
            let big: Int64
            let half: Double
        }
        let script = Script(
            name: "nums",
            sources: Sources.single("return { values = function() return { small = 3, big = 2^40, half = 2.5 } end }")
        )
        let data = (try? script.query("values")) ?? .nil
        let okData = data["small"].asInt64 == 3 && data["big"].asInt64 == (1 << 40) && data["half"].asDouble == 2.5
        let decoded = try? data.decode(Values.self)
        let ok = okData && decoded == Values(small: 3, big: 1 << 40, half: 2.5)
        return Check(
            name: "numbers",
            ok: ok,
            detail: "small=\(data["small"].asInt64 ?? -1) big=\(data["big"].asInt64 ?? -1) half=\(data["half"].asDouble ?? -1) decoded=\(String(describing: decoded))"
        )
    }

    private static func checkHostSignalAndAsync() -> Check {
        let options = ScriptOptions().setup { host in
            let signal = try host.signal("changed")
            let double = try host.asyncFunction("double") { args, done in
                let n: Double
                switch args.first {
                case .number(let x): n = x
                default: n = 0
                }
                DispatchQueue.global().async {
                    done.complete(.number(n * 2.0))
                }
            }
            let module = LuauTable()
            module.rawSet("changed", value: signal)
            module.rawSet("double", value: double)
            host.registerModule("@app/host", value: .table(module))
        }
        let src = "local host = require('@app/host')\nlocal seen = {}\nhost.changed:Connect(function(v) seen.signal = v end)\nreturn { start = function() seen.async = host.double(21) end, seen = function() return seen end }"
        let script = Script(name: "host", sources: Sources.single(src), options: options)
        _ = script.fire("changed", args: [.string("hello")])
        try? script.call("start")
        let rt = Runtime(state: (), viewport: Vec2(10, 10), pixelScale: 1.0, systemDark: true) { _, _ in el() }
        var now = 0.0
        for _ in 0..<400 {
            now += 1.0 / 120.0
            _ = rt.updateIf(at: now) { _, tx in script.poll(now: now, tx: &tx) }
            if let seen = try? script.query("seen"), seen["async"] != .nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        let seen = (try? script.query("seen")) ?? .nil
        let ok = seen["signal"].asString == "hello" && seen["async"].asInt64 == 42
        return Check(name: "host signal and async", ok: ok, detail: "signal=\(seen["signal"].asString ?? "nil") async=\(seen["async"].asInt64 ?? -1)")
    }

    public static func main() {
        let report = run(scale: .native)
        print(report.formatted())
        print(report.json())
    }

    private static let rowsLuauSource = #"""
--!strict
local ui = require("@rune/ui")

export type Item = { id: number, name: string, size: number, done: boolean }

local NAMES = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet" }

local function items(n: number): { Item }
	local out = table.create(n)
	for i = 1, n do
		out[i] = { id = i, name = `{NAMES[(i - 1) % #NAMES + 1]} {i}`, size = (i * 7919) % 1000, done = i % 3 == 0 }
	end
	return out
end

local function shuffle(list: { Item }, seed: number)
	for i, item in list do
		item.size = (i * 7919 + seed * 104729) % 1000
	end
end

local function row(item: Item, selected: boolean, onPress: () -> ())
	return ui.row({
		key = item.id,
		w = "full",
		h = 28,
		px = 16,
		gap = 10,
		align = "center",
		fill = if selected then "control-off" else nil,
		hover = "hover",
		onPress = onPress,
	}, {
		ui.text(`#{item.id}`, { size = 11, mono = true, color = "text-secondary", w = 44 }),
		ui.text(item.name, { size = 13, grow = 1, truncate = true }),
		ui.box({ w = 100, h = 4, radius = 2, fill = "separator" }, {
			ui.box({ w = item.size / 10, h = 4, radius = 2, fill = ui.hex("#009fff") }),
		}),
		ui.text(if item.done then "done" else "open", {
			size = 11,
			color = if item.done then ui.hex("#30a46c") else "text-secondary",
			w = 36,
		}),
	})
end

local LABELS = {
	"Session", "Messages", "Provider", "Model", "Context limit", "Total tokens", "Usage", "Input tokens",
	"Output tokens", "Reasoning tokens", "Cache read", "Cache write", "User messages", "Assistant messages",
	"Total cost", "Created", "Last activity", "System prompt", "Tools", "Files",
}

local function panel20(seed: number)
	local out = table.create(20)
	for i = 1, 20 do
		local value = (i * 7919 + seed * 31) % 100000
		out[i] = ui.row({ key = i, w = "full", h = 24, px = 16, gap = 8, align = "center" }, {
			ui.text(LABELS[i], { size = 12, color = "text-secondary", w = 140 }),
			ui.text(`{value // 1000},{string.format("%03d", value % 1000)}`, { size = 12, grow = 1, mono = true }),
			ui.box({ w = 80, h = 4, radius = 2, fill = "separator" }, {
				ui.box({ w = (value % 100) * 0.8, h = 4, radius = 2, fill = ui.hex("#009fff") }),
			}),
		})
	end
	return ui.col({ key = "panel20", w = "full", py = 8 }, out)
end

return {
	items = items,
	shuffle = shuffle,
	row = row,
	panel20 = panel20,
}
"""#

    private static let initLuauSource = #"""
--!strict
local ui = require("@rune/ui")
local rows = require("@self/rows")

local state = {
	selected = 0,
	presses = 0,
	pulse = 0,
	pings = 0,
	shuffles = 0,
}

local items = rows.items(1000)
local listVersion = 0
local headerVersion = 0
local pulsing: thread? = nil
local pinged = require("@rune/signal").new()

local function changed(list: boolean)
	headerVersion += 1
	if list then
		listVersion += 1
	end
end

pinged:Connect(function(n: number)
	state.pings = n
	changed(false)
end)

local function select(i: number)
	state.selected = i
	state.presses += 1
	changed(true)
end

local function pulse()
	if pulsing then
		task.cancel(pulsing)
	end
	pulsing = task.spawn(function()
		for step = 10, 0, -1 do
			state.pulse = step
			changed(false)
			task.wait(0.08)
		end
		pulsing = nil
	end)
end

local function button(key: string, label: string, onPress: () -> ())
	return ui.row({
		key = key,
		px = 10,
		py = 4,
		radius = 6,
		fill = "control-off",
		hover = "hover",
		press = "press",
		onPress = onPress,
	}, { ui.text(label, { size = 12, weight = "medium" }) })
end

local function header()
	local selected = if state.selected > 0 then `#{state.selected}` else "none"
	return ui.col({ key = "header", w = "full", px = 16, pt = 14, pb = 10, gap = 8 }, {
		ui.row({ w = "full", gap = 8, align = "center" }, {
			ui.text("Luau panel", { size = 15, weight = "semibold" }),
			ui.spacer(),
			ui.text(`{#items} rows · selected {selected} · {state.presses} presses`, { size = 12, color = "text-secondary" }),
		}),
		ui.row({ w = "full", gap = 6, align = "center" }, {
			button("shuffle", "Shuffle", function()
				state.shuffles += 1
				rows.shuffle(items, state.shuffles)
				changed(true)
			end),
			button("pulse", "Pulse", pulse),
			button("ping", "Ping", function()
				pinged:Fire(state.pings + 1)
			end),
			ui.spacer(),
			ui.box({ w = 120, h = 6, radius = 3, fill = "separator" }, {
				ui.box({ w = state.pulse * 12, h = 6, radius = 3, fill = ui.hex("#009fff") }),
			}),
			ui.text(`{state.pings} pings`, { size = 12, color = "text-secondary", w = 60 }),
		}),
	})
end

local function render(view)
	return ui.col({ key = "panel", w = "full", h = "full", fill = "bg" }, {
		view:Memo("header", headerVersion, header),
		ui.box({ w = "full", h = 1, fill = "separator" }),
		ui.virtualList({
			key = "items",
			w = "full",
			grow = 1,
			count = #items,
			estimatedRowHeight = 28,
			version = listVersion,
			renderRow = function(i: number)
				return rows.row(items[i], i == state.selected, function()
					select(i)
				end)
			end,
		}),
	})
end

return {
	render = render,
	select = select,
	selected = function()
		return state.selected
	end,
	panel20 = function(view)
		return rows.panel20(state.presses)
	end,
	saveHotState = function()
		return state
	end,
	loadHotState = function(saved)
		for k, v in saved do
			state[k] = v
		end
		rows.shuffle(items, state.shuffles)
	end,
}
"""#
}
