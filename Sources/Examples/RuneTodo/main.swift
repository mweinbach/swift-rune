import Foundation
import Rune

/// Port of `examples/todo`: scrollable animated task list with text input, completion progress bar,
/// filter pills, and enter/exit presence transitions.
struct TodoItem: Equatable {
    var id: Int
    var title: String
    var done: Bool
}

enum TodoFilter: String, CustomStringConvertible {
    case all = "All"
    case active = "Active"
    case completed = "Done"
    var description: String { rawValue }
}

struct TodoState {
    var nextId: Int = 5
    var draft = TextEdit("")
    var filter: TodoFilter = .all
    var items: [TodoItem] = [
        TodoItem(id: 1, title: "Port analytic Spring & Scene engine", done: true),
        TodoItem(id: 2, title: "Build instanced Metal & CPU uber-shader", done: true),
        TodoItem(id: 3, title: "Shape CoreText glyphs into R8 shelf atlas", done: false),
        TodoItem(id: 4, title: "Verify pixel parity with RuneRef", done: false),
    ]

    mutating func addDraft() {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(id: nextId, title: trimmed, done: false))
        nextId += 1
        draft.clear()
    }
}

func todoView(_ s: TodoState, _ cx: inout Cx<TodoState>) -> El<TodoState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)

    let doneCount = s.items.filter(\.done).count
    let progressFrac: Float = s.items.isEmpty ? 0 : Float(doneCount) / Float(s.items.count)

    let filtered = s.items.filter { item in
        switch s.filter {
        case .all: return true
        case .active: return !item.done
        case .completed: return item.done
        }
    }

    let inputRow: El<TodoState> = row()
        .wFull()
        .gap(8)
        .itemsCenter()
        .child(
            textInput(key: "todo-input", \.draft)
                .grow(1)
                .h(36)
                .px(12)
                .py(8)
                .rounded(Tok.Radius.md)
                .bg(t.controlTrack)
                .border(1, t.cardBorder)
                .size(14)
                .color(t.text)
                .placeholder("Add a new task...", color: t.textSecondary.alpha(0.6))
                .caret(accent)
                .focusRing(accent)
                .autofocus()
                .onSubmit { state, _, _ in state.addDraft() }
        )
        .child(
            row()
                .key("add-btn")
                .h(36)
                .px(14)
                .center()
                .rounded(Tok.Radius.md)
                .bg(accent)
                .pressScale(0.96)
                .focusRing(accent)
                .onClick { state in state.addDraft() }
                .child(text("Add").size(13).semibold().color(.white))
        )

    var list: El<TodoState> = col()
        .key("todo-list")
        .wFull()
        .grow(1)
        .minH(0)
        .gap(6)
        .scroll()

    for item in filtered {
        let itemId = item.id
        let rowEl: El<TodoState> = row()
            .key("item-\(itemId)")
            .wFull()
            .px(12)
            .py(10)
            .gap(10)
            .itemsCenter()
            .rounded(Tok.Radius.md)
            .bg(t.card)
            .border(1, t.cardBorder)
            .hover(t.hover)
            .animateLayout(Tok.Motion.DEFAULT)
            .transition(Transition.push(from: .bottom).spring(Tok.Motion.SNAPPY))
            .child(
                row()
                    .key("toggle-\(itemId)")
                    .role(.checkbox)
                    .selected(item.done ? "true" : "false")
                    .square(18)
                    .center()
                    .rounded(5)
                    .bg(item.done ? accent : .transparent)
                    .border(1.5, item.done ? accent : t.textSecondary)
                    .onClick { state in
                        if let idx = state.items.firstIndex(where: { $0.id == itemId }) {
                            state.items[idx].done.toggle()
                        }
                    }
                    .child(item.done ? text("✓").size(11).bold().color(.white) : nil)
            )
            .child(
                text(item.title)
                    .grow(1)
                    .size(14)
                    .color(item.done ? t.textSecondary : t.text)
            )
            .child(
                row()
                    .key("del-\(itemId)")
                    .px(6)
                    .py(2)
                    .rounded(4)
                    .hover(t.press)
                    .onClick { state in
                        state.items.removeAll { $0.id == itemId }
                    }
                    .child(text("×").size(15).color(t.textSecondary))
            )
        list = list.child(rowEl)
    }

    let filterBar: El<TodoState> = row()
        .gap(6)
        .children([TodoFilter.all, .active, .completed].map { f -> El<TodoState> in
            let active = (s.filter == f)
            return row()
                .key("filter-\(f.rawValue.lowercased())")
                .px(10)
                .py(4)
                .rounded(Tok.Radius.pill)
                .bg(active ? accent.alpha(0.18) : .transparent)
                .hover(t.hover)
                .onClick { state in state.filter = f }
                .child(text(f.rawValue).size(12).medium().color(active ? accent : t.textSecondary))
        })

    return col()
        .sizeFull()
        .p(24)
        .gap(16)
        .bg(t.bg)
        .child(
            row()
                .wFull()
                .itemsCenter()
                .justifyBetween()
                .child(text("Tasks").size(22).bold().color(t.text))
                .child(filterBar)
        )
        .child(
            row()
                .wFull()
                .h(6)
                .pill()
                .bg(t.controlTrack)
                .clip(true)
                .child(
                    el()
                        .key("progress-fill")
                        .wFrac(progressFrac)
                        .hFull()
                        .pill()
                        .bg(accent)
                        .animateLayout(Tok.Motion.DEFAULT)
                )
        )
        .child(inputRow)
        .child(list)
}

let spec = AppSpec<TodoState>(
    title: "Rune Todo",
    size: Vec2(480, 560),
    state: TodoState(),
    view: todoView
)

try RuneApp.run(spec)
