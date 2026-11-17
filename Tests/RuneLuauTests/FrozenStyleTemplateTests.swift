import Testing
import Rune
import RuneLuau

@Suite("Frozen Luau style templates")
struct FrozenStyleTemplateTests {
    @Test func layersKeepFreshContentChildrenAndNodeKinds() throws {
        let script = Script(name: "layers", sources: .single("""
            local ui = require("@rune/ui")
            local style = table.freeze({ pad = 8, pl = 3, opacity = 0.8 })
            local n = 0
            return { render = function()
                n += 1
                local own = { pad = 12, pt = 1, opacity = 0.5, key = n }
                return ui.col(style, {
                    ui.row(style, own, { ui.text("row {1}", style, n) }),
                    ui.box(style, { ui.text(n, style, own) }),
                    ui.spacer(style),
                    ui.text("whole {1}", style, n),
                })
            end }
            """))
        let first = script.renderUncached(name: "render", dark: false, Int.self)
        let second = script.renderUncached(name: "render", dark: false, Int.self)
        let typed = script.renderUncached(name: "render", dark: false, String.self)

        #expect(first.layout.direction == .column)
        try #require(first.children.count == 4 && second.children.count == 4 && typed.children.count == 4)
        let row = second.children[0]
        #expect(row.layout.direction == .row)
        #expect(row.layout.padding.top == 1)
        #expect(row.layout.padding.left == 3)
        #expect(row.layout.padding.right == 12)
        #expect(row.keyId == "2")
        #expect(row.opacity == 0.5)
        #expect(second.layout.padding.top == 8)
        #expect(second.opacity == 0.8)
        #expect(first.children[0].children.first?.plainText == "row 1")
        #expect(row.children.first?.plainText == "row 2")
        #expect(second.children[1].children.first?.plainText == "2")
        #expect(second.children[1].children.first?.keyId == "2")
        #expect(second.children[2].layout.flexGrow == 1)
        #expect(second.children[3].plainText == "whole 2")
        #expect(typed.children[3].plainText == "whole 3")
    }

    @Test func paletteAndNestedMutableValuesRefresh() throws {
        final class Theme: @unchecked Sendable {
            var colors: [String: Color] = [:]
            var elevation: Float = 1
            var paletteCalls: [String: Int] = [:]
        }
        let theme = Theme()
        let options = ScriptOptions().palette { name, _ in
            theme.paletteCalls[name, default: 0] += 1
            return theme.colors[name]
        }.shadows { _, _ in
            [Shadow(x: 0, y: 0, blur: theme.elevation, spread: 0, color: .black)]
        }
        let script = Script(name: "palette", sources: .single("""
            local ui = require("@rune/ui")
            local corners = { 1, 2, 3, 4 }
            local geo = table.freeze({ corners = corners })
            local shadow = table.freeze({ shadow = "raised" })
            local style = table.freeze({ fill = "accent", borderWidth = 2 })
            local pick = table.freeze({ selected = true })
            return { render = function()
                corners[1] += 1
                return ui.col({
                    ui.text("one", style), ui.text("two", style), ui.box(pick),
                    ui.box(shadow), ui.box(geo),
                })
            end }
            """), options: options)

        let a = script.renderUncached(name: "render", dark: false, Int.self)
        try #require(a.children.count == 5)
        #expect(a.children[0].background == .transparent)
        #expect(a.children[0].borderColor == .transparent)
        #expect(a.children[0].textColor == .black)
        #expect(a.children[3].shadows.first?.blur == 1)
        #expect(a.children[4].corners.topLeft == 2)

        let red = Color.srgb(1, 0, 0)
        let blue = Color.srgb(0, 0, 1)
        theme.colors = ["accent": red, "text": blue, "separator": red, "selected": blue]
        theme.elevation = 9
        let b = script.renderUncached(name: "render", dark: false, Int.self)
        try #require(b.children.count == 5)
        #expect(b.children[1].background == red)
        #expect(b.children[1].borderColor == red)
        #expect(b.children[1].textColor == blue)
        #expect(b.children[2].background == blue)
        #expect(b.children[3].shadows.first?.blur == 9)
        #expect(b.children[4].corners.topLeft == 3)
        #expect(a.children[1].textColor == .black)

        theme.colors = [:]
        let dark = script.renderUncached(name: "render", dark: true, Int.self)
        try #require(dark.children.count == 5)
        #expect(dark.children[0].textColor == .white)
        #expect(dark.children[0].background == .transparent)
        #expect(theme.paletteCalls["accent"] == 3)
        #expect(theme.paletteCalls["text"] == 3)
    }

    @Test func handlersKeepEachSnapshotAndExpireOnReload() throws {
        let sources = Sources.single("""
            local ui = require("@rune/ui")
            local label, n = "", 0
            local style = table.freeze({ pad = 4 })
            local handlers = table.freeze({
                onMiddlePress = function(e) label = e.key end,
                onHover = function(e) label = "hover:" .. e.key end,
            })
            return {
                render = function()
                    n += 1
                    local i = n
                    return ui.col({
                        ui.box(style, { key = i, onPress = function(e) label = i .. ":" .. e.key end }),
                        ui.box(handlers, { key = i }),
                    })
                end,
                label = function() return label end,
            }
            """)
        let script = Script(name: "callbacks", sources: sources)
        let first = script.renderUncached(name: "render", dark: false, Int.self)
        let second = script.renderUncached(name: "render", dark: false, Int.self)
        try #require(first.children.count == 2 && second.children.count == 2)
        var state = 0
        var tx = Tx()
        let oldPress = try #require(first.children[0].handlers.onClick)
        oldPress(&state, &tx)
        #expect(try script.query("label") == .string("1:1"))
        let secondPress = try #require(second.children[0].handlers.onClick)
        secondPress(&state, &tx)
        #expect(try script.query("label") == .string("2:2"))
        let oldMiddle = try #require(first.children[1].handlers.onMiddlePress)
        oldMiddle(&state, &tx)
        #expect(try script.query("label") == .string("1"))
        let secondHover = try #require(second.children[1].handlers.onHover)
        secondHover(&state, true, &tx)
        #expect(try script.query("label") == .string("hover:2"))

        try script.reload(sources)
        oldPress(&state, &tx)
        oldMiddle(&state, &tx)
        #expect(try script.query("label") == .string(""))
    }

    @Test func cacheRetainsTableIdentityUntilCapacityOrReload() throws {
        final class Probe: @unchecked Sendable {
            weak var table: LuauTable?
        }
        let probe = Probe()
        let options = ScriptOptions().timeLimit(.seconds(10)).setup { host in
            host.global("remember", value: .nativeFunction(LuauNativeFunction(name: "remember") { _, _, args in
                if case .table(let table) = args.first { probe.table = table }
                return .values([])
            }))
        }
        let sources = Sources.single("""
            local ui = require("@rune/ui")
            return {
                one = function()
                    local style = table.freeze({ opacity = 0.75 })
                    remember(style)
                    return ui.text("old", style)
                end,
                many = function()
                    for i = 1, 1024 do
                        ui.text(i, table.freeze({ key = i }))
                    end
                    return ui.text("done")
                end,
                callback = function()
                    local style = table.freeze({ onPress = function() end })
                    remember(style)
                    return ui.box(style)
                end,
            }
            """)
        let script = Script(name: "capacity", sources: sources, options: options)
        let old = script.renderUncached(name: "one", dark: false, Int.self)
        #expect(old.plainText == "old")
        #expect(probe.table != nil)
        let last = script.renderUncached(name: "many", dark: false, Int.self)
        #expect(last.plainText == "done")
        #expect(probe.table == nil)
        #expect(old.opacity == 0.75)
        _ = script.renderUncached(name: "callback", dark: false, Int.self)
        #expect(probe.table == nil)
        _ = script.renderUncached(name: "one", dark: false, Int.self)
        #expect(probe.table != nil)
        try script.reload(sources)
        #expect(probe.table == nil)
    }
}
