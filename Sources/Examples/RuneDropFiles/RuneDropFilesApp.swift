import Foundation
import Rune

/// Port of `examples/drop-files`: drop zones for pictures and any file, with hover highlight and status.
public struct DropFilesState: Sendable {
    public var over: String? = nil
    public var last: (String, [DroppedFile])? = nil
    public var dropState = FileDropState()
    public var acceptedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic"]

    public init(over: String? = nil, last: (String, [DroppedFile])? = nil) {
        self.over = over
        self.last = last
    }
}

public func formatNames(_ files: [DroppedFile]) -> String {
    files.map(\.name).joined(separator: ", ")
}

private func dropZone(
    _ s: DropFilesState,
    accent: Color,
    key: String,
    title: String,
    detail: String,
    extensions: [String]? = nil
) -> El<DropFilesState> {
    let t = Tok.theme(dark: true)
    let over = s.over == key
    var zone: El<DropFilesState> = col()
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
        .onDropHover { state, hovered, _ in
            if hovered {
                state.over = key
            } else if state.over == key {
                state.over = nil
            }
        }
        .onDropFiles { state, urls, _ in
            let files = urls.map { DroppedFile(url: $0) }
            state.dropState.handle(.dropped(files, at: .zero))
            print("drop \(key) \(formatNames(files))")
            state.last = (key, files)
        }
    if let extensions {
        zone = zone.acceptsExtensions(extensions)
    }
    return zone
}

public func dropFilesView(_ s: DropFilesState, _ cx: inout Cx<DropFilesState>) -> El<DropFilesState> {
    let t = Tok.theme(dark: true)
    let accent = cx.accent()
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
        .onDropFiles { state, urls, _ in
            let files = urls.map { DroppedFile(url: $0) }
            state.dropState.handle(.dropped(files, at: .zero))
            print("drop window \(formatNames(files))")
            state.last = ("window", files)
        }
        .child(
            row()
                .gap(12)
                .child(dropZone(
                    s,
                    accent: accent,
                    key: "pictures",
                    title: "Pictures",
                    detail: "PNG, JPEG, GIF or HEIC",
                    extensions: Array(s.acceptedImageExtensions).sorted()
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

@main
public enum RuneDropFilesApp {
    public static func buildSpec() -> AppSpec<DropFilesState> {
        AppSpec<DropFilesState>(
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
    }

    public static func main() throws {
        try RuneApp.run(buildSpec())
    }
}
