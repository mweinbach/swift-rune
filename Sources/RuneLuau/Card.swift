import Foundation
import Rune

internal enum LuauCard {
    static func errorCard<State>(
        message: String,
        palette: Palette,
        dark: Bool,
        onReload: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        func color(_ name: String, _ fallback: Color) -> Color {
            palette(name, dark) ?? fallback
        }
        let fg = color("text", dark ? .white : .black)
        let weak = color("text-secondary", fg.alpha(0.7))
        let danger = Color.hex("#e5484d") ?? fg

        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = lines.first ?? "script error"
        let rest = Array(lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(12))

        let reloadBtn = (row() as El<State>)
            .key("luau-reload")
            .px(10)
            .py(4)
            .rounded(6)
            .bg(color("control-off", weak.alpha(0.2)))
            .hover(color("hover", weak.alpha(0.1)))
            .child(
                (text("Reload") as El<State>)
                    .font(TextStyle(size: 12, weight: 500))
                    .color(fg)
            )
            .label("Reload script")
            .onClick(onReload)

        var card = (col() as El<State>)
            .key("luau-error")
            .wFull()
            .p(12)
            .gap(8)
            .rounded(8)
            .bg(color("card", .transparent))
            .border(1.0, danger)
            .child(
                (text("Stopped drawing: \(first)") as El<State>)
                    .font(TextStyle(size: 13, weight: 500, wrap: .wrap))
                    .color(fg)
                    .wFull()
            )

        if !rest.isEmpty {
            card = card.child(
                (text(rest.joined(separator: "\n")) as El<State>)
                    .font(TextStyle(size: 11, weight: 400, family: .monospace, wrap: .wrap))
                    .color(weak)
                    .wFull()
            )
        }

        return card.child((row() as El<State>).child(reloadBtn))
    }

    static func rowError<State>(message: String) -> El<State> {
        let danger = Color.hex("#e5484d") ?? .white
        let first = message.split(separator: "\n").first.map(String.init) ?? "row failed"
        return (text(first) as El<State>)
            .font(TextStyle(size: 11, weight: 400, family: .monospace))
            .color(danger)
            .ellipsis()
            .wFull()
    }
}
