import Foundation
import Rune

/// Port of `examples/drop-files`: drop zones for pictures and any file, with hover highlight and status.
struct DropFilesState {
    var over: String? = nil
    var last: (String, [DroppedFile])? = nil
    var dropState = FileDropState()
    var acceptedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic"]
}

func formatNames(_ files: [DroppedFile]) -> String {
    files.map(\.name).joined(separator: ", ")
}

func dropZone(
    _ s: DropFilesState,
    accent: Color,
    key: String,
    title: String,
    detail: String,
    extensions: Set<String>? = nil
) -> El<DropFilesState> {
    let t = Tok.theme(dark: true)
    let over = s.over == key
    return col()
        .key(key)
        .size(200, 120)
        .p(12)
        .gap(4)
        .rounded(Tok.Radius.lg)
        .center()
        .bg(over ? accent.alpha(0.18) : t.card)
        .border(over ? 2 : 1, over ? accent : t.cardBorder)
        .child(text(title).size(15).semibold().color(t.text))
        .child(text(detail).size(12).medium().color(t.textSecondary))
        .onHover { state, hovered, _ in
            if hovered {
                state.over = key
            } else if state.over == key {
                state.over = nil
            }
        }
        .onClick { state in
            // Interactive demo simulation when clicked
            let sample = extensions != nil
                ? DroppedFile(path: "/tmp/sunset.png", name: "sunset.png", sizeBytes: 42_180)
                : DroppedFile(path: "/tmp/notes.txt", name: "notes.txt", sizeBytes: 1_024)
            state.dropState.handle(.dropped([sample], at: Vec2(260, 120)))
            print("drop \(key) \(sample.name)")
            state.last = (key, [sample])
        }
}

func dropFilesView(_ s: DropFilesState, _ cx: inout Cx<DropFilesState>) -> El<DropFilesState> {
    let t = Tok.theme(dark: true)
    let accent = cx.focusColor()
    let status: String = if let (target, files) = s.last {
        "Dropped on \(target): \(formatNames(files))"
    } else {
        "Drag files from another app onto a zone"
    }

    return col()
        .sizeFull()
        .center()
        .gap(24)
        .bg(t.bg)
        .child(
            row()
                .gap(12)
                .child(dropZone(
                    s,
                    accent: accent,
                    key: "pictures",
                    title: "Pictures",
                    detail: "PNG, JPEG, GIF or HEIC",
                    extensions: s.acceptedImageExtensions
                ))
                .child(dropZone(
                    s,
                    accent: accent,
                    key: "anything",
                    title: "Anything",
                    detail: "Any file"
                ))
        )
        .child(text(status).key("status").size(13).color(t.textSecondary))
}

let spec = AppSpec<DropFilesState>(
    title: "Drop Files",
    size: Vec2(520, 240),
    dark: true,
    state: DropFilesState(),
    view: dropFilesView
)
.scene("idle") { $0.over = nil; $0.last = nil }
.scene("hover-pictures") { $0.over = "pictures"; $0.last = nil }
.scene("dropped-pictures") {
    $0.over = nil
    $0.last = ("pictures", [DroppedFile(path: "/tmp/a.png", name: "a.png", sizeBytes: 2048)])
}
.scene("dropped-window") {
    $0.over = nil
    $0.last = ("window", [DroppedFile(path: "/tmp/notes.txt", name: "notes.txt", sizeBytes: 512)])
}

try RuneApp.run(spec)
