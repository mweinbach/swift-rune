import Foundation
import Rune

/// Port of `examples/drag-out`: drag a file, an app bundle, or a line of text out of a Rune window.
public struct DragOutState: Sendable {
    public var file: URL
    public var app: URL
    public var last: (String, DragOutcome)? = nil
    public var dragging: String? = nil

    public init(
        file: URL,
        app: URL,
        last: (String, DragOutcome)? = nil,
        dragging: String? = nil
    ) {
        self.file = file
        self.app = app
        self.last = last
        self.dragging = dragging
    }

    public static func initial() -> DragOutState {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Dragged out of Rune.txt")
        try? "This file was dragged out of a Rune window.\n".write(to: file, atomically: true, encoding: .utf8)
        #if os(macOS)
        let exampleApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #else
        let exampleApp = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        #endif
        let app = ProcessInfo.processInfo.environment["DRAG_OUT_APP"].map { URL(fileURLWithPath: $0) } ?? exampleApp
        return DragOutState(file: file, app: app)
    }
}

public func dragOutTile(
    _ s: DragOutState,
    key: String,
    title: String,
    detail: String,
    makeItem: @escaping @Sendable (DragOutState) -> DragItem
) -> El<DragOutState> {
    let t = Tok.theme(dark: true)
    let isDragging = s.dragging == key
    let container: El<DragOutState> = col()
    return container
        .key(key)
        .role(.button)
        .cursor(.grab)
        .size(150, 92)
        .p(12)
        .gap(4)
        .rounded(Tok.Radius.lg)
        .bg(t.card)
        .border(1, t.cardBorder)
        .hover(t.hover)
        .press(t.press)
        .opacity(isDragging ? 0.28 : 1.0)
        .child(text(title).size(15).semibold().color(t.text))
        .child(text(detail).size(12).medium().color(t.textSecondary))
        .dragOut { state in
            makeItem(state).opaque(t.bg)
        }
        .onDragStart { state, _ in
            state.dragging = key
        }
        .onDragOutEnd { state, outcome, _ in
            print("drag-end \(key) \(outcome)")
            state.dragging = nil
            state.last = (key, outcome)
        }
}

public func dragOutView(_ s: DragOutState, _ cx: inout Cx<DragOutState>) -> El<DragOutState> {
    let t = Tok.theme(dark: true)
    let status: String = if let (key, outcome) = s.last {
        "Last drag: \(key), \(outcome)"
    } else {
        "Drag a tile out of the window"
    }

    return col()
        .sizeFull()
        .center()
        .gap(24)
        .bg(t.bg)
        .child(
            row()
                .gap(12)
                .child(dragOutTile(s, key: "file", title: "A file", detail: s.file.lastPathComponent) {
                    DragItem().file($0.file)
                })
                .child(dragOutTile(s, key: "app", title: "An app", detail: s.app.lastPathComponent) {
                    DragItem().file($0.app)
                })
                .child(dragOutTile(s, key: "text", title: "Some text", detail: "Hello from Rune") { _ in
                    DragItem().text("Hello from Rune")
                })
        )
        .child(text(status).key("status").size(13).color(t.textSecondary))
}

@main
public enum RuneDragOutApp {
    public static func buildSpec() -> AppSpec<DragOutState> {
        AppSpec<DragOutState>(
            title: "Drag Out",
            size: Vec2(520, 200),
            dark: true,
            state: DragOutState.initial(),
            view: dragOutView
        )
    }

    public static func main() throws {
        try RuneApp.run(buildSpec())
    }
}
