import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/glyphs.rs`:
/// every built-in `KitIcons` glyph at 16 pt, labelled, light beside dark.
@main
enum RuneKitGlyphsApp {
    struct State: Sendable {}

    static let catalog: [(name: String, svg: SVGIcon)] = [
        ("check", KitIcons.check),
        ("check-small", KitIcons.checkSmall),
        ("chevron-down", KitIcons.chevronDown),
        ("chevron-up", KitIcons.chevronUp),
        ("caret-right", KitIcons.caretRight),
        ("triangle-down", KitIcons.triangleDown),
        ("triangle-right", KitIcons.triangleRight),
        ("close", KitIcons.close),
        ("copy", KitIcons.copy),
        ("search", KitIcons.search),
        ("circle-x", KitIcons.circleX),
        ("lock", KitIcons.lock),
        ("eye", KitIcons.eye),
        ("eye-off", KitIcons.eyeOff),
        ("dash", KitIcons.dash),
        ("folder", KitIcons.folder),
        ("folder-open", KitIcons.folderOpen),
        ("file", KitIcons.file),
        ("file-code", KitIcons.fileCode),
        ("file-text", KitIcons.fileText),
        ("file-image", KitIcons.fileImage),
        ("mic", KitIcons.mic),
        ("keyboard", KitIcons.keyboard),
        ("cursor-text", KitIcons.cursorText),
        ("arrow-right", KitIcons.arrowRight),
        ("sparkle", KitIcons.sparkle),
        ("star", KitIcons.star),
        ("star-filled", KitIcons.starFilled),
    ]

    static func panel(dark: Bool) -> El<State> {
        let k = Kit.neutral(dark: dark)
        func tile(_ name: String, _ svg: SVGIcon) -> El<State> {
            col()
                .key("\(dark ? "dark" : "light")-\(name)")
                .w(96)
                .h(64)
                .gap(8)
                .itemsCenter()
                .justifyCenter()
                .child(icon(svg, size: 16).color(k.c.textBase))
                .child(text(name).font(k.ty.textXsmall).color(k.c.textFaint))
        }

        var rows: El<State> = col().gap(0)
        var idx = 0
        while idx < catalog.count {
            let end = min(idx + 5, catalog.count)
            var r: El<State> = row()
            for j in idx..<end {
                r = r.child(tile(catalog[j].name, catalog[j].svg))
            }
            rows = rows.child(r)
            idx = end
        }

        return col()
            .grow(1)
            .hFull()
            .p(10)
            .bg(k.c.page)
            .itemsCenter()
            .justifyCenter()
            .child(rows)
    }

    static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        row()
            .wFull()
            .hFull()
            .child(panel(dark: false))
            .child(panel(dark: true))
    }

    static func makeApp() -> App<State> {
        App(title: "Glyphs", size: Vec2(1000, 540), state: State(), view: view)
    }

    static func main() throws {
        try makeApp().run()
    }
}
