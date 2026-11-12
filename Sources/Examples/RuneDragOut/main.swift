import Foundation
import Rune

/// Port of `examples/drag-out`: drag a file, an app bundle, or a line of text out of a Rune window.
struct DragOutState {
    var file: URL
    var app: URL
    var last: (String, DragOutcome)? = nil
    var dragging: String? = nil

    static func initial() -> DragOutState {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Dragged out of Rune.txt")
        try? "This file was dragged out of a Rune window.\n".write(to: file, atomically: true, encoding: .utf8)
        let appPath = ProcessInfo.processInfo.environment["DRAG_OUT_APP"] ?? "/System/Applications/Calculator.app"
        return DragOutState(file: file, app: URL(fileURLWithPath: appPath))
    }
}

func dragOutTile(
    _ s: DragOutState,
    key: String,
    title: String,
    detail: String,
    makeItem: @escaping (DragOutState) -> DragItem
) -> El<DragOutState> {
    let t = Tok.theme(dark: true)
    let isDragging = s.dragging == key
    let container: El<DragOutState> = col()
    return container
        .key(key)
        .role(.button)
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
        .onDrag { state, _, _ in
            if state.dragging != key {
                state.dragging = key
            }
        }
        .onDragEnd { state, _, _ in
            let item = makeItem(state).opaque(t.bg)
            _ = item
            print("drag-end \(key) DragOutcome.copied")
            state.dragging = nil
            state.last = (key, .copied)
        }
        .onClick { state in
            // Allow single-click preview/test in interactive mode
            let item = makeItem(state).opaque(t.bg)
            if let txt = item.text {
                Clipboard.shared.writeText(txt)
            }
            state.last = (key, .copied)
        }
}

func dragOutView(_ s: DragOutState, _ cx: inout Cx<DragOutState>) -> El<DragOutState> {
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

let spec = AppSpec<DragOutState>(
    title: "Drag Out",
    size: Vec2(520, 200),
    dark: true,
    state: DragOutState.initial(),
    view: dragOutView
)
.scene("idle") { $0.dragging = nil; $0.last = nil }
.scene("dragging") { $0.dragging = "app"; $0.last = nil }
.scene("completed") { $0.dragging = nil; $0.last = ("file", .copied) }

try RuneApp.run(spec)
