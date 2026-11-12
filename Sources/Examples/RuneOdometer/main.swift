import Foundation
import Rune
import RuneKit
import RuneMotion

struct OdometerState {
    var n: Int = 9
    var cents: Int = 42
    var tokens: UInt64 = 12_345
}

private let usageSpring = Spring(duration: 0.3, bounce: 0.0)

private func tokensShort(_ n: UInt64) -> String {
    if n >= 1_000 {
        return String(format: "%.1fK", Double(n) / 1000.0)
    }
    return "\(n)"
}

private func headerRow(
    _ k: Kit,
    _ s: OdometerState,
    name: String,
    trailingCost: Bool,
    leads: Bool
) -> El<OdometerState> {
    let font = TextStyle(size: 12.0, weight: 440.0, lineHeight: 16.0).mono()
    let layoutAnim: LayoutAnim = leads ? .widthLeads(usageSpring) : LayoutAnim(spring: usageSpring)

    let ctxLabel: El<OdometerState> = k.rollingText(
        key: "\(name)-ctx",
        tokensShort(s.tokens),
        font: font,
        color: k.c.textWeak
    )
    let costText = String(format: "$%d.%02d", s.cents / 100, s.cents % 100)
    let costLabel: El<OdometerState> = k.rollingText(
        key: "\(name)-cost",
        costText,
        font: font,
        color: k.c.textWeak
    )

    let usage: El<OdometerState> = row()
        .key("\(name)-usage")
        .gap(6)
        .itemsCenter()
        .animateLayout(layoutAnim)
        .child(el().size(14, 14).rounded(7).border(2, k.c.borderBase))
        .child(ctxLabel)
        .child(costLabel)

    return row()
        .key(name)
        .w(300)
        .h(32)
        .px(10)
        .gap(8)
        .itemsCenter()
        .bg(k.c.bgDeep)
        .child(
            row()
                .key("\(name)-crumbs")
                .itemsCenter()
                .shrink(1)
                .child(
                    text("Refactor the session list so pinned rows keep their place")
                        .font(TextStyle(size: 13.0, weight: 530.0))
                        .ellipsis()
                )
        )
        .child(el().grow(1))
        .child(usage)
}

private func odometerView(_ s: OdometerState, _ cx: inout Cx<OdometerState>) -> El<OdometerState> {
    let k = Kit.neutral(dark: true)
    let big = TextStyle(size: 28.0, weight: 600.0).mono()

    let count: El<OdometerState> = k.rollingText(key: "count", "\(s.n)", font: big)
    let time: El<OdometerState> = k.rollingText(key: "secs", "\(s.n)s", font: k.ty.mono)

    let buttons: El<OdometerState> = row()
        .gap(8)
        .child(k.button(key: "up", "Up") { state, _ in state.n += 1 })
        .child(k.button(key: "down", "Down") { state, _ in state.n -= 1 })
        .child(k.button(key: "step", "Step") { state, _ in
            state.cents += 7
            state.tokens += 1_400
        })
        .child(k.button(key: "big", "Big step") { state, _ in
            state.cents += 996
            state.tokens += 98_000
        })

    return col()
        .wFull()
        .hFull()
        .p(24)
        .gap(16)
        .bg(k.c.bgBase)
        .child(buttons)
        .child(count)
        .child(
            row()
                .w(160)
                .justifyEnd()
                .animateLayout(k.motion.control)
                .child(time)
        )
        .child(headerRow(k, s, name: "head", trailingCost: true, leads: true))
        .child(headerRow(k, s, name: "head-lead", trailingCost: false, leads: true))
        .child(headerRow(k, s, name: "head-plain", trailingCost: true, leads: false))
}

let spec = AppSpec(
    title: "Odometer",
    size: Vec2(420, 360),
    state: OdometerState(),
    view: odometerView
)
.scene("stepped") {
    $0.n = 10
    $0.cents = 49
    $0.tokens = 13_745
}
.scene("big") {
    $0.n = 100
    $0.cents = 1045
    $0.tokens = 111_745
}

try RuneApp.run(spec)
