import Foundation
import Rune

/// Parity port of `crates/rune/examples/popup_menu.rs`:
/// Native pop-up menus with a settings-style picker that opens over its button
/// and a context menu on secondary press.
@main
public enum RunePopupMenuApp {
    public struct State: Sendable, Equatable {
        public var theme: String
        public var last: String

        public init(theme: String = "system", last: String = "-") {
            self.theme = theme
            self.last = last
        }
    }

    public static let themes: [(String, String)] = [
        ("system", "System"),
        ("light", "Light"),
        ("dark", "Dark"),
    ]

    public static func themeTitle(_ id: String) -> String {
        themes.first { $0.0 == id }?.1 ?? "System"
    }

    public static func popupMenuSupported() -> Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public static func contextMenu() -> PopupMenu {
        PopupMenu()
            .item("copy", "Copy", keyEquivalent: "mod+c", symbolName: "doc.on.doc")
            .item("paste", "Paste", enabled: false)
            .separator()
            .submenu(
                "Share",
                PopupMenu()
                    .item("mail", "Mail")
                    .item("messages", "Messages")
            )
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        col().p(24).gap(16)
            .child(
                row().gap(12).centerY()
                    .child(text("Theme"))
                    .child(
                        row()
                            .key("theme")
                            .p(6)
                            .rounded(6)
                            .bg(oklch(0.45, 0.02, 260.0))
                            .child(text(themeTitle(s.theme)))
                            .onClick { s, tx in
                                let menu = PopupMenu.picker(themes, selected: s.theme)
                                tx.popupMenu(menu, at: "theme") { (s: inout State, picked, _) in
                                    if let id = picked {
                                        s.theme = id
                                    }
                                }
                            }
                    )
            )
            .child(
                el()
                    .key("canvas")
                    .size(272, 80)
                    .rounded(8)
                    .bg(oklch(0.3, 0.02, 260.0))
                    .child(text("Secondary-click for a context menu").p(8))
                    .onSecondaryClick { _, press, tx in
                        tx.popupMenu(contextMenu(), at: press) { (s: inout State, picked, _) in
                            s.last = picked ?? "(dismissed)"
                        }
                    }
            )
            .child(text("Last: \(s.last)  ·  native menus: \(popupMenuSupported())"))
    }

    public static func makeApp() -> App<State> {
        App(
            title: "Rune pop-up menus",
            size: Vec2(320, 220),
            state: State(),
            view: view
        )
    }

    public static func main() throws {
        try makeApp().run()
    }
}
