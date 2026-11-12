import Foundation
import Rune
import RuneLuau

/// Port of `examples/luau-panel`: a Rune app hosting a Luau script (`scripts/panel`) with
/// a header, `task.wait` pulse, `@rune/signal`, and a 1,000-row `ui.virtualList`.
struct LuauPanelState {
    var script: Script
    var surfaceName: String = "render"

    static func embeddedSources() -> Sources {
        Sources()
            .with("init.luau", initLuauSource)
            .with("rows.luau", rowsLuauSource)
    }

    static func initial() -> LuauPanelState {
        let options = ScriptOptions().onLog { level, line in
            fputs("luau-panel \(level.rawValue): \(line)\n", stderr)
        }
        let script = Script(name: "panel", sources: embeddedSources(), options: options)
        return LuauPanelState(script: script)
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

-- Reorders sizes deterministically for round `seed`.
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

-- Twenty label/value/bar rows, values computed per build as a stats tab's would be.
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

func luauPanelView(_ s: LuauPanelState, _ cx: inout Cx<LuauPanelState>) -> El<LuauPanelState> {
    let panel = s.surfaceName == "render"
        ? s.script.view(cx)
        : s.script.surface(cx, name: s.surfaceName)
    return col()
        .sizeFull()
        .child(panel)
}

let spec = AppSpec<LuauPanelState>(
    title: "Luau panel",
    size: Vec2(720, 640),
    dark: true,
    state: LuauPanelState.initial(),
    view: luauPanelView
)
.scene("panel") { $0.surfaceName = "render" }
.scene("panel20") { $0.surfaceName = "panel20" }

try RuneApp.run(spec)
