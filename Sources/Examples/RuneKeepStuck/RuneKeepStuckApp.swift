import Foundation
import Rune

/// Port of `crates/rune/examples/keep_stuck.rs`: a long tool group in a chat timeline
/// whose sticky header opens/closes with `Tx.keepOnScreen("hdr")`.
public struct KeepStuckChat: Sendable {
    public var open: Bool

    public init(open: Bool = true) {
        self.open = open
    }
}

private let keepStuckSteps = 40

private func bubble(_ key: String, _ h: Float) -> El<KeepStuckChat> {
    let box: El<KeepStuckChat> = col()
    return box
        .key(key)
        .wFull()
        .h(h)
        .rounded(10.0)
        .p(10.0)
        .bg(oklch(0.32, 0.02, 250.0))
        .child(text(key).font(TextStyle(size: 13.0, weight: 500.0)).color(.white))
}

private func toolGroup(_ s: KeepStuckChat) -> El<KeepStuckChat> {
    let label = s.open ? "Used 40 tools  ▾" : "Used 40 tools  ▸"
    var header: El<KeepStuckChat> = row()
        .key("hdr")
        .wFull()
        .h(28.0)
        .px(10.0)
        .itemsCenter()
        .bg(oklch(0.2, 0.01, 250.0))
        .child(text(label).font(TextStyle(size: 13.0, weight: 500.0)).color(.white))
        .onClick { st, tx in
            st.open.toggle()
            tx.keepOnScreen("hdr")
        }
    if s.open {
        header = header.stickyTop(0.0)
    }

    let stepRows: [El<KeepStuckChat>] = (0..<keepStuckSteps).map { k in
        let suffix = String(format: "%02d", k)
        let rowEl: El<KeepStuckChat> = row()
        return rowEl
            .key("step-\(k)")
            .wFull()
            .h(28.0)
            .itemsCenter()
            .child(
                text("Read src/net/stream_\(suffix).rs")
                    .font(TextStyle(size: 12.0, weight: 400.0))
                    .color(oklch(0.75, 0.01, 250.0))
            )
    }
    let steps: El<KeepStuckChat> = col()
        .key("steps")
        .wFull()
        .px(10.0)
        .children(stepRows)

    // Shut, the steps stay laid out under a box with no height, and the row's clip folds them.
    let baseHeld: El<KeepStuckChat> = col().key("steps-box").wFull()
    let held = (s.open ? baseHeld : baseHeld.h(0.0)).child(steps)

    return col()
        .key("turn")
        .wFull()
        .clipSoft(0.0)
        .child(
            col()
                .key("group")
                .wFull()
                .child(header)
                .child(held)
        )
}

public func keepStuckView(_ s: KeepStuckChat, _ cx: inout Cx<KeepStuckChat>) -> El<KeepStuckChat> {
    let rows: [El<KeepStuckChat>] = [
        bubble("m0", 120.0),
        bubble("m1", 60.0),
        toolGroup(s),
        bubble("answer", 90.0),
        bubble("actions", 36.0),
    ]
    let stack: El<KeepStuckChat> = col()
        .key("timeline")
        .wFull()
        .p(16.0)
        .gap(8.0)
        .growth(.default)
        .virtualize(56.0)
        .children(rows)
    return col()
        .wFull()
        .hFull()
        .bg(oklch(0.2, 0.01, 250.0))
        .child(
            col()
                .key("scroll")
                .wFull()
                .grow(1.0)
                .minH(0.0)
                .scroll(ScrollSpec(stickBottom: true))
                .child(stack)
        )
}

@main
public enum RuneKeepStuckApp {
    public static func makeSpec() -> AppSpec<KeepStuckChat> {
        AppSpec<KeepStuckChat>(
            title: "Keep a stuck header",
            size: Vec2(420.0, 360.0),
            state: KeepStuckChat(open: true),
            view: keepStuckView
        )
    }

    public static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
