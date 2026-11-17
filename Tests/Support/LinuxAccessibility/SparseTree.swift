import Rune

@main
enum SparseTree {
    struct State {
        var items = ["C", "A", "B"]
        var renamed = false
        var heading = false
        var scrolled = false
    }

    static func button(_ key: String, _ label: String, _ press: @escaping (inout State, inout Tx) -> Void = { _, _ in }) -> El<State> {
        text(label).key(key).role(.button).label(label).focusable()
            .size(104, 32).shrink(0).onClick(press)
    }

    static func view(_ state: State, _: inout Cx<State>) -> El<State> {
        let actions: El<State> = row().key("actions").label("Actions").gap(4)
            .child(button("rename", "Rename") { state, tx in
                state.renamed = true
                tx.setTitle("Rune sparse ATK probe — renamed")
            })
            .child(button("reorder", "Reorder") { state, _ in
                if let last = state.items.popLast() { state.items.insert(last, at: 0) }
            })
            .child(button("remove", "Remove") { state, _ in state.items.removeAll { $0 == "B" } })
            .child(button("scroll", "Scroll") { state, tx in
                state.scrolled.toggle()
                tx.scrollToY("viewport", state.scrolled ? 30 : 0)
                tx.setTitle("Rune sparse ATK probe — scroll \(state.scrolled ? 30 : 0)")
            })
            .child(button("retype", "Retype") { state, _ in state.heading.toggle() })
        let items: El<State> = row().key("items").label("Items").gap(4)
            .children(state.items.map { button("item-" + $0, $0 == "A" && state.renamed ? "A edited" : $0) })
        let viewport: El<State> = col().key("viewport").label("Viewport").size(200, 100).shrink(0).scrollY()
            .child(button("edge-item", "Edge item").h(20))
            .child(el().role(.presentation).h(24).shrink(0))
            .child(button("scroll-item", "Scroll item"))
            .child(el().role(.presentation).h(120).shrink(0))
        let roleBox: El<State> = col().key("role-box").role(state.heading ? .heading : .group).label("Role box")
            .child(button("retained-child", "Retained child"))
        return col().key("fixture").label("Fixture").sizeFull().p(8).gap(8)
            .child(actions).child(items).child(viewport).child(roleBox)
    }

    static func main() throws {
        try RuneApp.run(AppSpec(title: "Rune sparse ATK probe", size: Vec2(620, 300), state: State(), view: view))
    }
}
