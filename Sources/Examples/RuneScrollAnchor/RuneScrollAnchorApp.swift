import Foundation
import Rune

/// Port of `crates/rune/examples/scroll_anchor.rs`: a scrolled feed with `El.scrollAnchor()`
/// keeping the reading position steady while new messages arrive above (`Enter`).
/// Pass `plain` to disable scroll anchoring.
public struct ScrollAnchorFeed: Sendable {
    public var earlier: Int
    public var anchor: Bool

    public init(earlier: Int = 0, anchor: Bool = true) {
        self.earlier = earlier
        self.anchor = anchor
    }
}

private let scrollAnchorRows = 40

private func feedMessage(_ key: String, _ label: String, _ h: Float) -> El<ScrollAnchorFeed> {
    let box: El<ScrollAnchorFeed> = row()
    return box
        .key(key)
        .wFull()
        .h(h)
        .px(14.0)
        .itemsCenter()
        .rounded(10.0)
        .bg(oklch(0.26, 0.015, 250.0))
        .child(text(label).font(TextStyle(size: 13.0, weight: 500.0)).color(.white))
}

public func scrollAnchorView(_ s: ScrollAnchorFeed, _ cx: inout Cx<ScrollAnchorFeed>) -> El<ScrollAnchorFeed> {
    let earlierRows: [El<ScrollAnchorFeed>] = (0..<s.earlier).reversed().map { k in
        feedMessage("earlier-\(k)", "Earlier \(k)", 64.0)
    }
    let rows: [El<ScrollAnchorFeed>] = (0..<scrollAnchorRows).map { k in
        let suffix = String(format: "%02d", k)
        return feedMessage("msg-\(k)", "Message \(suffix)", 48.0 + Float(k % 3) * 16.0)
    }
    let list: El<ScrollAnchorFeed> = col()
        .key("list")
        .wFull()
        .p(12.0)
        .gap(8.0)
        .growth(.default)
        .children(earlierRows + rows)
    let feed: El<ScrollAnchorFeed> = col()
        .key("feed")
        .wFull()
        .grow(1.0)
        .scroll(ScrollSpec(stickBottom: false))
        .child(list)
    return col()
        .wFull()
        .hFull()
        .bg(oklch(0.18, 0.01, 250.0))
        .child(s.anchor ? feed.scrollAnchor() : feed)
}

public func onScrollAnchorKey(_ s: inout ScrollAnchorFeed, _ e: KeyEvent, _: inout Tx) -> Bool {
    guard e.key == .enter else { return false }
    s.earlier += 3
    return true
}

@main
public enum RuneScrollAnchorApp {
    public static func makeApp(arguments: [String]? = nil) -> App<ScrollAnchorFeed> {
        let extra = ToolingProcessArgs.extraArgs(argv: arguments ?? Array(CommandLine.arguments.dropFirst()))
        let anchor = !extra.contains("plain")
        return App(
            title: "Keep the reading position",
            size: Vec2(420.0, 400.0),
            state: ScrollAnchorFeed(earlier: 0, anchor: anchor),
            view: scrollAnchorView
        )
        .onKey(onScrollAnchorKey)
    }

    public static func makeSpec(arguments: [String]? = nil) -> AppSpec<ScrollAnchorFeed> {
        makeApp(arguments: arguments).intoSpec()
    }

    public static func main() throws {
        try makeApp().run()
    }
}
