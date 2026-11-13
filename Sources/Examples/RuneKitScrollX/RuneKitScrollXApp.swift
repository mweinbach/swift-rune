import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/scroll_x.rs`:
/// horizontal filmstrip above a wide Markdown code block and table inside a scrolling page.
@main
enum RuneKitScrollXApp {
    struct State: Sendable {}

    static let codeMarkdown = """
    ```rust
    fn main() {
        let frames: Vec<Frame> = clips.iter().flat_map(|clip| clip.frames_between(start, end)).filter(|f| f.keyframe).collect();
        println!("{} keyframes across {} clips, first at {:?}", frames.len(), clips.len(), frames.first().map(|f| f.at));
    }
    ```
    """

    static let tableMarkdown = """
    | Clip | Codec | Resolution | Frame rate | Duration | Keyframe interval | Size |
    |---|---|---|---|---|---|---|
    | Harbour at dawn | HEVC Main 10 | 3840 × 2160 | 59.94 | 00:01:12 | 2 s | 812 MB |
    | Night market | ProRes 422 HQ | 4096 × 2160 | 25 | 00:00:48 | every frame | 3.9 GB |
    | Ridge line | AV1 | 2560 × 1440 | 30 | 00:02:05 | 4 s | 214 MB |
    """

    static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let k = Kit.neutral(dark: true)

        var stripRow: El<State> = row().gap(10)
        for i in 0..<12 {
            let tile: El<State> = col()
                .key("tile\(i)")
                .w(132)
                .h(96)
                .rounded(10)
                .p(10)
                .justifyEnd()
                .bg(oklch(0.62, 0.13, 25.0 + 31.0 * Float(i)))
                .child(text("Clip \(i + 1)").font(Tok.Typography.title).color(.white))
            stripRow = stripRow.child(tile)
        }

        let strip: El<State> = col()
            .key("strip")
            .wFull()
            .h(96)
            .scrollX()
            .child(stripRow)

        let codeBlock: El<State> = col()
            .key("code")
            .wFull()
            .scrollX()
            .child(k.markdown(codeMarkdown, key: "code-md"))

        let tableBlock: El<State> = col()
            .key("table")
            .wFull()
            .scrollX()
            .child(k.markdown(tableMarkdown, key: "table-md"))

        let page: El<State> = col()
            .wFull()
            .p(20)
            .gap(16)
            .child(text("Filmstrip").font(Tok.Typography.title).color(k.c.textBase))
            .child(strip)
            .child(codeBlock)
            .child(tableBlock)
            .child(el().h(240))

        return col()
            .wFull()
            .hFull()
            .bg(k.c.page)
            .child(
                col()
                    .key("page")
                    .wFull()
                    .hFull()
                    .scroll(stickBottom: false)
                    .child(page)
            )
    }

    static func makeApp() -> App<State> {
        App(title: "Horizontal scrolling", size: Vec2(520, 520), state: State(), view: view)
    }

    static func main() throws {
        try makeApp().run()
    }
}
