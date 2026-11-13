import Foundation
import Rune

/// Port of `crates/rune/examples/custom_titlebar.rs`.
///
/// A window that draws its own titlebar (`App.titlebar`): a 44 point band that drags the
/// window, with buttons in it that keep their presses. `Cx.chromeInsets` reports the platform
/// chrome bounds; "Theme" switches colors and `Cx.captionColor`; "Zoom" scales the band via
/// `Cx.titlebarHeight`; "Dialog" opens a click-outside-dismissible modal while leaving window
/// controls usable.

public let customTitlebarHeight: Float = 44.0
public let customTitlebarZooms: [Float] = [1.0, 1.25, 0.8]

public struct CustomTitlebarState: Sendable {
    public var dark: Bool?
    public var presses: UInt32
    public var zoom: Int
    public var dialog: Bool
    public var note: TextEdit

    public init(
        dark: Bool? = nil,
        presses: UInt32 = 0,
        zoom: Int = 0,
        dialog: Bool = false,
        note: TextEdit = TextEdit("")
    ) {
        self.dark = dark
        self.presses = presses
        self.zoom = zoom
        self.dialog = dialog
        self.note = note
    }
}

public func customTitlebarView(
    _ s: CustomTitlebarState,
    _ cx: inout Cx<CustomTitlebarState>
) -> El<CustomTitlebarState> {
    let dark = s.dark ?? cx.getSystemDark()
    let (bg, band, ink, faint): (Color, Color, Color, Color) = if dark {
        (oklch(0.18, 0.0, 0.0), oklch(0.22, 0.0, 0.0), oklch(0.95, 0.0, 0.0), oklch(0.65, 0.0, 0.0))
    } else {
        (oklch(0.99, 0.0, 0.0), oklch(0.95, 0.0, 0.0), oklch(0.2, 0.0, 0.0), oklch(0.5, 0.0, 0.0))
    }

    cx.captionColor(dark ? .white : .black)
    let bandHeight = customTitlebarHeight * customTitlebarZooms[s.zoom % customTitlebarZooms.count]
    cx.titlebarHeight(bandHeight)
    let insets = cx.chromeInsets()

    func button(_ key: String, _ labelText: String) -> El<CustomTitlebarState> {
        row()
            .key(key)
            .px(10.0)
            .h(28.0)
            .rounded(6.0)
            .centerY()
            .bg(faint.alpha(0.2))
            .hover(faint.alpha(0.3))
            .press(faint.alpha(0.45))
            .role(.button)
            .label(labelText)
            .child(text(labelText).color(ink))
    }

    let zoomButton: El<CustomTitlebarState> = button("zoom", "Zoom")
        .onClick { s in
            s.zoom = (s.zoom + 1) % customTitlebarZooms.count
        }
    let dialogButton: El<CustomTitlebarState> = button("dialog", "Dialog")
        .onClick { s in
            s.dialog = true
        }
    let themeButton: El<CustomTitlebarState> = button("theme", "Theme")
        .onClick { s in
            s.dark = !dark
            s.presses += 1
        }

    let titlebar: El<CustomTitlebarState> = row()
        .key("titlebar")
        .wFull()
        .h(bandHeight)
        .bg(band)
        .centerY()
        .windowDrag()
        .pl(insets.leading + 12.0)
        .pr(insets.trailing + 12.0)
        .gap(8.0)
        .child(text("Custom titlebar").color(ink))
        .child(el().grow(1.0))
        .child(zoomButton)
        .child(dialogButton)
        .child(themeButton)

    func line(_ t: String, key: String? = nil) -> El<CustomTitlebarState> {
        var labelEl: El<CustomTitlebarState> = text(t).color(faint)
        if let key {
            labelEl = labelEl.key(key)
        }
        return labelEl
    }

    let note: El<CustomTitlebarState> = textInput(key: "note", \.note)
        .noWrap()
        .font(TextStyle(size: 14.0, weight: 400.0))
        .w(320.0)
        .p(8.0)
        .rounded(6.0)
        .bg(band)
        .color(ink)
        .placeholder("Type here, then Alt+Space", color: faint)
        .label("Note")

    let closeDialogButton: El<CustomTitlebarState> = button("close-dialog", "Close")
        .onClick { s in
            s.dialog = false
        }

    let dialogEl: El<CustomTitlebarState>? = s.dialog
        ? el()
            .key("scrim")
            .pin(top: 0.0, right: 0.0, bottom: 0.0, left: 0.0)
            .bg(Color.black.alpha(0.35))
            .center()
            .child(
                col()
                    .key("sheet")
                    .p(20.0)
                    .gap(12.0)
                    .rounded(10.0)
                    .bg(bg)
                    .role(.dialog)
                    .label("Dialog")
                    .modal(clickOutside: true) { s in
                        s.dialog = false
                    }
                    .child(text("A modal. The caption buttons still work.").color(ink))
                    .child(closeDialogButton)
            )
        : nil

    let body: El<CustomTitlebarState> = col()
        .p(24.0)
        .gap(8.0)
        .child(
            text("Drag the band to move the window; double-click it to maximize; right-click it for the window menu.")
                .color(ink)
                .wrapText()
        )
        .child(note)
        .child(line(
            String(
                format: "chrome insets: leading %.0f, trailing %.0f, height %.0f",
                insets.leading,
                insets.trailing,
                insets.height
            ),
            key: "insets-line"
        ))
        .child(line(
            String(format: "scale %.2f, theme presses %u", cx.env().scale, s.presses),
            key: "status-line"
        ))

    var root: El<CustomTitlebarState> = col()
        .key("root")
        .wFull()
        .hFull()
        .bg(bg)
        .child(titlebar)
        .child(body)
    if let dialogEl {
        root = root.child(dialogEl)
    }
    return root
}

public func makeApp() -> App<CustomTitlebarState> {
    App(
        title: "Custom titlebar",
        size: Vec2(720.0, 420.0),
        state: CustomTitlebarState(),
        view: customTitlebarView
    )
    .titlebar(Titlebar(height: customTitlebarHeight))
}

@main
enum RuneCustomTitlebarMain {
    static func main() throws {
        try makeApp().run()
    }
}
