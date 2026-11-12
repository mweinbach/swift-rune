import Foundation
import Rune
import RuneMotion

struct TodoItem: Equatable {
    var id: Int
    var title: String
    var done: Bool
}

struct TodoState {
    var todos: [TodoItem]
    var next: Int

    init() {
        let titles = ["Write the view", "Run it headless", "Ship it"]
        self.todos = titles.enumerated().map { id, title in
            TodoItem(id: id, title: title, done: id == 0)
        }
        self.next = 3
    }
}

func todoProgress(_ done: Int, _ total: Int, _ t: ThemeTokens) -> El<TodoState> {
    let width: Float = 312.0 * Float(done) / Float(max(1, total))
    return el()
        .key("track")
        .wFull()
        .h(4)
        .rounded(2)
        .bg(t.controlOff)
        .child(
            el()
                .key("bar")
                .w(width)
                .h(4)
                .rounded(2)
                .bg(Tok.accent(0, dark: true))
                .animateLayout(LayoutAnim(spring: Spring(duration: 0.4, bounce: 0.2)))
        )
}

func todoView(_ s: TodoState, _ cx: inout Cx<TodoState>) -> El<TodoState> {
    let t = Tok.theme(dark: true)
    var list: El<TodoState> = col().key("list").gap(4)
    for todo in s.todos {
        let id = todo.id
        let check: El<TodoState> = el()
            .key("check")
            .size(16, 16)
            .rounded(8)
            .bg(todo.done ? Tok.accent(0, dark: true) : t.controlOff)
            .onClick { state in
                if let idx = state.todos.firstIndex(where: { $0.id == id }) {
                    state.todos[idx].done.toggle()
                }
            }
        let title: El<TodoState> = text(todo.title)
            .font(Tok.Typography.body)
            .grow(1)
            .color(todo.done ? t.textSecondary : t.text)
        let remove: El<TodoState> = text("Remove")
            .font(Tok.Typography.label)
            .color(t.textSecondary)
            .onClick { state in
                state.todos.removeAll { $0.id == id }
            }
        list = list.child(
            row()
                .key("todo-\(id)")
                .h(36)
                .px(12)
                .gap(12)
                .centerY()
                .rounded(Tok.Radius.sm)
                .bg(t.card)
                .child(check)
                .child(title)
                .child(remove)
        )
    }

    let add: El<TodoState> = text("Add a todo")
        .key("add")
        .font(Tok.Typography.label)
        .color(Tok.accent(0, dark: true))
        .onClick { state in
            state.todos.append(TodoItem(id: state.next, title: "Todo \(state.next + 1)", done: false))
            state.next += 1
        }

    let done = s.todos.filter(\.done).count
    return col()
        .wFull()
        .hFull()
        .p(24)
        .gap(12)
        .bg(t.bg)
        .child(todoProgress(done, s.todos.count, t))
        .child(list.scroll(stickBottom: true).shrink(1).minH(0))
        .child(add)
}

@main
enum RuneTodoApp {
    static func makeSpec() -> AppSpec<TodoState> {
        AppSpec<TodoState>(
            title: "Todo",
            size: Vec2(360, 240),
            state: TodoState(),
            view: todoView
        )
    }

    static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
