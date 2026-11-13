import Foundation
import Rune
import RuneKit
import RuneMotion

private let odometerUsageSpring = Spring(duration: 0.3, bounce: 0.0)

public struct OdometerState: Sendable {
    public var n: Int = 9
    public var cents: Int = 42
    public var tokens: UInt64 = 12_345
    public var store: RollingTextStore = RollingTextStore()

    public init() {}
}

public func odometerView(_ s: OdometerState, _ cx: inout Cx<OdometerState>) -> El<OdometerState> {
    let k = Kit.neutral(dark: cx.systemDark)
    let c = k.c
    let big = TextStyle(size: 28, weight: 600).mono()

    let count = RollingText<OdometerState>(
        key: "count",
        value: "\(s.n)",
        numericValue: Double(s.n),
        font: big,
        color: c.textBase,
        kit: k,
        store: s.store
    )
    .build()

    let time = row()
        .w(160)
        .justifyEnd()
        .animate(RollingText<OdometerState>.defaultSpring)
        .child(
            RollingText<OdometerState>(
                key: "secs",
                value: "\(s.n)s",
                numericValue: Double(s.n),
                font: k.ty.mono,
                color: c.textMuted,
                trailing: true,
                kit: k,
                store: s.store
            )
            .build()
        )

    let buttons = row()
        .gap(8)
        .children([
            k.button(key: "up", "Up") { (s: inout OdometerState, _) in
                s.n += 1
            },
            k.button(key: "down", "Down") { (s: inout OdometerState, _) in
                s.n -= 1
            },
            k.button(key: "step", "Step") { (s: inout OdometerState, _) in
                s.cents += 7
                s.tokens += 1_400
            },
            k.button(key: "big", "Big step") { (s: inout OdometerState, _) in
                s.cents += 996
                s.tokens += 98_000
            },
        ])

    return col()
        .sizeFull()
        .bg(c.bgBase)
        .p(24)
        .gap(16)
        .children([
            text("RollingText")
                .font(k.ty.small)
                .color(c.textFaint),
            row()
                .gap(24)
                .itemsCenter()
                .children([count, time]),
            odometerHeader(key: "head", s: s, k: k, trailingCost: true, leads: true),
            odometerHeader(key: "head-lead", s: s, k: k, trailingCost: false, leads: true),
            odometerHeader(key: "head-plain", s: s, k: k, trailingCost: true, leads: false),
            buttons,
        ])
}

private func odometerHeader(
    key: String,
    s: OdometerState,
    k: Kit,
    trailingCost: Bool,
    leads: Bool
) -> El<OdometerState> {
    let c = k.c
    let cost = String(format: "$%.2f", Double(s.cents) / 100.0)
    let ctx = formatOdometerTokens(s.tokens)

    var usage: El<OdometerState> = row()
        .gap(6)
        .itemsCenter()
        .children([
            col().w(14).h(14).rounded(7).bg(c.borderStrong),
            RollingText<OdometerState>(
                key: "\(key)-ctx",
                value: ctx,
                numericValue: Double(s.tokens),
                font: k.ty.textXsmall.mono(),
                color: c.textFaint,
                trailing: true,
                kit: k,
                store: s.store
            )
            .build(),
            RollingText<OdometerState>(
                key: "\(key)-cost",
                value: cost,
                numericValue: Double(s.cents),
                font: k.ty.textXsmall.mono(),
                color: c.textMuted,
                trailing: trailingCost,
                kit: k,
                store: s.store
            )
            .build(),
        ])
    usage = leads
        ? usage.animateLayout(LayoutAnim.widthLeads(odometerUsageSpring))
        : usage.animate(odometerUsageSpring)

    return row()
        .key(key)
        .w(300)
        .h(32)
        .px(10)
        .gap(8)
        .itemsCenter()
        .bg(c.bgDeep)
        .rounded(k.radius.md)
        .children([
            text("Refactor the session list so pinned rows keep their place")
                .font(k.ty.smallMedium)
                .color(c.textBase)
                .shrink(1)
                .minW(0)
                .ellipsis(),
            spacer(),
            usage,
        ])
}

private func formatOdometerTokens(_ n: UInt64) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    } else if n >= 1_000 {
        return "\(n / 1_000)k"
    } else {
        return "\(n)"
    }
}

@main
public enum RuneOdometerApp {
    public static func makeSpec() -> AppSpec<OdometerState> {
        AppSpec(
            title: "Odometer",
            size: Vec2(420, 360),
            state: OdometerState(),
            view: odometerView
        )
    }

    public static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
