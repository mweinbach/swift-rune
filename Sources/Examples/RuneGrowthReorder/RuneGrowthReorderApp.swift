import Foundation
import Rune

/// Port of `crates/rune/examples/growth_reorder.rs`: rows trading places in a growth stack
/// slide from where they were drawn into their new places. Supports `virtual` and `steer` args.
public struct GrowthReorderChat: Sendable {
    public var rows: [(key: String, height: Float)]
    public var virtualised: Bool
    public var steer: Bool
    public var sent: Int

    public init(
        rows: [(key: String, height: Float)],
        virtualised: Bool = false,
        steer: Bool = false,
        sent: Int = 0
    ) {
        self.rows = rows
        self.virtualised = virtualised
        self.steer = steer
        self.sent = sent
    }

    public static func initial(extraArgs: [String]) -> GrowthReorderChat {
        let virtualised = extraArgs.contains("virtual")
        let steer = extraArgs.contains("steer")
        let rows: [(key: String, height: Float)] = if virtualised {
            (0..<40).map { i in ("v\(i)", i % 2 == 0 ? 36.0 : 77.0) }
        } else {
            [("m0", 120.0), ("m1", 60.0), ("m2", 90.0), ("bubble-p", 36.0), ("working", 77.0)]
        }
        return GrowthReorderChat(rows: rows, virtualised: virtualised, steer: steer, sent: 0)
    }
}

private func tapRow(_ s: inout GrowthReorderChat, _ key: String) {
    if s.steer && key == "working" {
        deliverPrompt(&s)
        return
    }
    guard let i = s.rows.firstIndex(where: { $0.key == key }) else { return }
    let j = if i + 1 < s.rows.count { i + 1 } else { i > 0 ? i - 1 : 0 }
    s.rows.swapAt(i, j)
}

private func sendPrompt(_ s: inout GrowthReorderChat, _ tx: inout Tx) {
    let key = "steer-\(s.sent)"
    s.sent += 1
    tx.launch("draft", to: "\(key)/label")
    s.rows.append((key, 53.0))
}

private func deliverPrompt(_ s: inout GrowthReorderChat) {
    guard let w = s.rows.firstIndex(where: { $0.key == "working" }), w + 1 < s.rows.count else {
        return
    }
    var row = s.rows.remove(at: w + 1)
    row.height = 77.0
    s.rows.insert(row, at: w)
}

public func growthReorderView(_ s: GrowthReorderChat, _ cx: inout Cx<GrowthReorderChat>) -> El<GrowthReorderChat> {
    let working = s.rows.firstIndex(where: { $0.key == "working" })
    let rowEls: [El<GrowthReorderChat>] = s.rows.enumerated().map { i, item in
        let tint = item.key == "working" ? oklch(0.42, 0.06, 250.0) : oklch(0.32, 0.02, 250.0)
        var label: El<GrowthReorderChat> = text(item.key == "working" ? "Working…" : item.key)
            .font(TextStyle(size: 13.0, weight: 500.0))
            .color(.white)
        if s.steer {
            label = label.key("label")
        }
        var rowEl: El<GrowthReorderChat> = col()
            .key(item.key)
            .wFull()
            .h(item.height)
            .rounded(10.0)
            .p(10.0)
            .bg(tint)
        if s.steer && item.key.hasPrefix("steer-") {
            let belowSecondPending = working.map { i > $0 + 1 } ?? false
            rowEl = rowEl.pt(belowSecondPending ? 4.0 : 18.0)
        }
        return rowEl
            .child(label)
            .onClick { st in
                tapRow(&st, item.key)
            }
    }

    var stack: El<GrowthReorderChat> = col()
        .key("timeline")
        .wFull()
        .p(16.0)
        .gap(8.0)
        .growth(.default)
        .children(rowEls)
    if s.virtualised {
        stack = stack.virtualize(56.0)
    }

    let page: El<GrowthReorderChat> = col()
        .wFull()
        .hFull()
        .bg(oklch(0.2, 0.01, 250.0))
        .child(
            col()
                .key("scroll")
                .wFull()
                .grow(1.0)
                .minH(0.0)
                .scroll(ScrollSpec(stickBottom: !s.virtualised))
                .child(stack)
        )
    if !s.steer {
        return page
    }
    return page.child(
        col()
            .key("composer")
            .wFull()
            .h(56.0)
            .p(16.0)
            .bg(oklch(0.26, 0.01, 250.0))
            .child(
                text("steer-next")
                    .key("draft")
                    .font(TextStyle(size: 13.0, weight: 500.0))
                    .color(.white)
            )
            .onClick { st, tx in
                sendPrompt(&st, &tx)
            }
    )
}

@main
public enum RuneGrowthReorderApp {
    public static func makeSpec(arguments: [String]? = nil) -> AppSpec<GrowthReorderChat> {
        let extra = ToolingProcessArgs.extraArgs(argv: arguments ?? Array(CommandLine.arguments.dropFirst()))
        return AppSpec<GrowthReorderChat>(
            title: "Growth reorder",
            size: Vec2(420.0, 360.0),
            state: GrowthReorderChat.initial(extraArgs: extra),
            view: growthReorderView
        )
    }

    public static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
