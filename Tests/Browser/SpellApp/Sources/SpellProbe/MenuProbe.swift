import Foundation
import Rune

func menuProbe<State>() -> El<State> {
    let menu = PopupMenu()
        .item("current", "Current", checked: true)
        .item("disabled", "Unavailable", enabled: false)
        .separator()
        .submenu("Actions", PopupMenu().item("archive", "Archive").item("export", "Export"))
        .selected("current")
    return row().key("menu-anchor").role(.button).label("Actions").w(240).h(40)
        .onSecondaryClick { _, _, tx in
            tx.popupMenu(menu, at: "menu-anchor") { (_: inout State, choice: String?, _: inout Tx) in
                let answer = ["menuAnswer": choice ?? "dismissed"]
                if let data = try? JSONEncoder().encode(answer) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
        }
        .child(text("Actions"))
}
