import Foundation
import Rune

/// Port of `examples/launcher`: a Notes app with a ⌘Space / `/` Spotlight-style launcher overlay
/// supporting live search filtering, keyboard navigation (Up/Down/Enter/Escape), and note selection.
private struct NoteItem {
    var title: String
    var body: String
}

private let notes: [NoteItem] = [
    NoteItem(title: "Groceries", body: "Oat milk, lemons, basil, sourdough, two avocados."),
    NoteItem(title: "Trip to Lisbon", body: "Book the tram tour. Pastéis de nata first."),
    NoteItem(title: "Reading list", body: "The Design of Everyday Things. Thinking in Systems."),
    NoteItem(title: "Ideas", body: "A launcher that opens notes by typing their first letters."),
]

struct LauncherState {
    var selected: Int = 0
    var launcherOpen: Bool = false
    var query = TextEdit("")
    var picked: Int = 0
}

private func matchingIndices(_ query: String) -> [Int] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return Array(notes.indices) }
    return notes.indices.filter { notes[$0].title.lowercased().contains(q) }
}

private func openPicked(_ state: inout LauncherState) {
    let found = matchingIndices(state.query.text)
    guard !found.isEmpty else { return }
    let idx = min(state.picked, found.count - 1)
    state.selected = found[idx]
    state.query.clear()
    state.picked = 0
    state.launcherOpen = false
}

func launcherView(_ s: LauncherState, _ cx: inout Cx<LauncherState>) -> El<LauncherState> {
    let t = Tok.theme(dark: true)
    let accent = Tok.accent(0, dark: true)

    func trafficLight(_ c: Color) -> El<LauncherState> {
        el().square(12).rounded(6).bg(c)
    }

    let titleBar: El<LauncherState> = row()
        .h(38)
        .px(14)
        .gap(8)
        .itemsCenter()
        .child(trafficLight(Color(r: 1.0, g: 0.37, b: 0.34, a: 1.0)))
        .child(trafficLight(Color(r: 1.0, g: 0.74, b: 0.18, a: 1.0)))
        .child(trafficLight(Color(r: 0.16, g: 0.79, b: 0.25, a: 1.0)))
        .child(el().grow(1))
        .child(text("Notes").size(13).semibold().color(t.textSecondary))
        .child(el().grow(1))
        .child(
            row()
                .key("open-launcher-btn")
                .px(8)
                .py(4)
                .rounded(6)
                .bg(Color.white.alpha(0.08))
                .hover(Color.white.alpha(0.14))
                .onClick { state in
                    state.launcherOpen.toggle()
                    state.picked = 0
                }
                .child(text("⌘Space").size(11).medium().color(t.textSecondary))
        )

    var list: El<LauncherState> = col()
        .key("list")
        .w(170)
        .hFull()
        .px(8)
        .py(4)
        .gap(2)

    for (i, note) in notes.enumerated() {
        let on = (i == s.selected)
        let rowEl: El<LauncherState> = row()
            .key("note-\(i)")
            .wFull()
            .h(30)
            .px(10)
            .rounded(6)
            .itemsCenter()
            .bg(on ? accent.alpha(0.85) : .transparent)
            .hover(on ? accent.alpha(0.92) : t.hover)
            .onClick { state in state.selected = i }
            .child(text(note.title).size(13).color(on ? .white : t.text))
        list = list.child(rowEl)
    }

    let current = notes[s.selected]
    let page: El<LauncherState> = col()
        .key("page")
        .grow(1)
        .hFull()
        .p(20)
        .gap(10)
        .bg(t.bg)
        .child(text(current.title).size(18).semibold().color(t.text))
        .child(text(current.body).size(13).color(t.textSecondary))
        .child(el().grow(1))
        .child(text("⌘Space to search").size(11).color(t.textSecondary.alpha(0.7)))

    var root: El<LauncherState> = col()
        .key("root")
        .sizeFull()
        .bg(t.card)
        .child(titleBar)
        .child(
            row()
                .wFull()
                .grow(1)
                .child(list)
                .child(page)
        )

    if s.launcherOpen {
        let found = matchingIndices(s.query.text)
        let field: El<LauncherState> = textInput(key: "query", \.query)
            .grow(1)
            .size(16)
            .color(t.text)
            .placeholder("Search notes", color: t.textSecondary)
            .caret(accent)
            .autofocus()
            .onChange { state, _, _ in state.picked = 0 }
            .onSubmit { state, _, _ in openPicked(&state) }

        var panel: El<LauncherState> = col()
            .key("panel")
            .w(420)
            .rounded(14)
            .clip(true)
            .bg(t.card)
            .border(1, Color.white.alpha(0.14))
            .shadow(Shadow(y: 16, blur: 36, color: Color.black.alpha(0.55)))
            .transition(Transition.scale(0.96).combined(with: .opacity).spring(Tok.Motion.SNAPPY))
            .child(
                row()
                    .wFull()
                    .h(52)
                    .px(16)
                    .gap(10)
                    .itemsCenter()
                    .child(text("⌕").size(18).color(t.textSecondary))
                    .child(field)
            )

        if !found.isEmpty {
            var results: El<LauncherState> = col()
                .key("results")
                .wFull()
                .p(6)
                .gap(2)
            for (rowIdx, noteIdx) in found.enumerated() {
                let on = (rowIdx == min(s.picked, found.count - 1))
                let resRow: El<LauncherState> = row()
                    .key("result-\(noteIdx)")
                    .wFull()
                    .h(34)
                    .px(12)
                    .rounded(8)
                    .itemsCenter()
                    .bg(on ? accent.alpha(0.85) : .transparent)
                    .onClick { state in
                        state.selected = noteIdx
                        state.query.clear()
                        state.picked = 0
                        state.launcherOpen = false
                    }
                    .child(text(notes[noteIdx].title).size(13).color(on ? .white : t.text))
                results = results.child(resRow)
            }
            panel = panel
                .child(rule(1, t.separator))
                .child(results)
        }

        let scrim: El<LauncherState> = col()
            .key("launcher-scrim")
            .absolute(x: 0, y: 0)
            .sizeFull()
            .itemsCenter()
            .pt(48)
            .bg(Color.black.alpha(0.45))
            .child(panel)

        root = root.child(scrim)
    }

    return root
}

let spec = AppSpec<LauncherState>(
    title: "Rune Launcher",
    size: Vec2(560, 340),
    dark: true,
    state: LauncherState(),
    onKey: { state, event, _ in
        if event.key == .command(" ") || (event.key == .space && event.mods.cmd) || (!state.launcherOpen && event.key == .text("/")) {
            state.launcherOpen.toggle()
            state.picked = 0
            return true
        }
        guard state.launcherOpen else { return false }
        let n = matchingIndices(state.query.text).count
        switch event.key {
        case .arrowDown where n > 0:
            state.picked = (state.picked + 1) % n
            return true
        case .arrowUp where n > 0:
            state.picked = (state.picked + n - 1) % n
            return true
        case .enter:
            openPicked(&state)
            return true
        case .escape:
            state.launcherOpen = false
            return true
        default:
            return false
        }
    },
    view: launcherView
)
.scene("closed") { $0.launcherOpen = false }
.scene("open") {
    $0.launcherOpen = true
    $0.query.setText("")
    $0.picked = 1
}
.scene("filtered") {
    $0.launcherOpen = true
    $0.query.setText("li")
    $0.picked = 0
}

try RuneApp.run(spec)
