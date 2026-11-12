import Foundation
import Rune

private let barHeight: Float = 60.0
private let tabTitles = ["Inbox", "Today", "Later", "Done"]

enum BarLook {
    case soft
    case strong
    case plain
}

struct FrostedBarState {
    var tab: Int = 0
    var look: BarLook = .soft
}

private func listRow(_ i: Int, dark: Bool) -> El<FrostedBarState> {
    let t = Tok.theme(dark: dark)
    let hue = Float((i * 47) % 360)
    let swatch: El<FrostedBarState> = el()
        .size(40, 40)
        .rounded(12)
        .bg(oklch(dark ? 0.62 : 0.70, 0.16, hue))

    let lines: El<FrostedBarState> = col()
        .grow(1)
        .gap(3)
        .child(text("Item \(i + 1)").font(Tok.Typography.title).color(t.text))
        .child(text("A row that scrolls under the bar, hue \(Int(hue))").font(Tok.Typography.body).color(t.textSecondary))

    return row()
        .wFull()
        .px(16)
        .py(10)
        .gap(12)
        .itemsCenter()
        .child(swatch)
        .child(lines)
}

private func tabItem(_ i: Int, state: FrostedBarState, dark: Bool) -> El<FrostedBarState> {
    let t = Tok.theme(dark: dark)
    let on = state.tab == i
    let title = tabTitles[i]
    return col()
        .key(title)
        .role(.button)
        .label(title)
        .grow(1)
        .hFull()
        .center()
        .gap(4)
        .onClick { $0.tab = i }
        .child(
            el()
                .size(22, 4)
                .rounded(2)
                .bg(on ? Tok.accent(0, dark: dark) : t.controlOff)
        )
        .child(
            text(title)
                .font(TextStyle(size: 11, weight: on ? 650 : 500))
                .color(on ? t.text : t.textSecondary)
        )
}

private func frostedBarView(_ s: FrostedBarState, _ cx: inout Cx<FrostedBarState>) -> El<FrostedBarState> {
    let dark = cx.systemDark
    let t = Tok.theme(dark: dark)

    let rows: El<FrostedBarState> = col()
        .wFull()
        .pb(barHeight)
        .children((0..<60).map { listRow($0, dark: dark) })

    let list: El<FrostedBarState> = col()
        .key("list")
        .wFull()
        .hFull()
        .scroll(stickBottom: false)
        .child(rows)

    let (sigma, alpha): (Float, Float) = switch s.look {
    case .soft: (8.0, dark ? 0.40 : 0.45)
    case .strong: (20.0, dark ? 0.55 : 0.60)
    case .plain: (0.0, dark ? 0.40 : 0.45)
    }

    let tint = dark
        ? oklcha(0.20, 0.005, 265.0, alpha)
        : oklcha(0.98, 0.003, 265.0, alpha)

    let hairline: El<FrostedBarState> = el().wFull().h(0.5).bg(t.separator)
    let bar: El<FrostedBarState> = col()
        .key("bar")
        .pin(right: 0, bottom: 0, left: 0)
        .h(barHeight)
        .backdropBlur(sigma)
        .bg(tint)
        .child(hairline)
        .child(
            row()
                .wFull()
                .grow(1)
                .children((0..<tabTitles.count).map { tabItem($0, state: s, dark: dark) })
        )

    return el()
        .wFull()
        .hFull()
        .bg(t.bg)
        .child(list)
        .child(bar)
}

let spec = AppSpec(
    title: "Frosted bar",
    size: Vec2(390, 640),
    state: FrostedBarState(),
    view: frostedBarView
)
.scene("strong") { $0.look = .strong }
.scene("plain") { $0.look = .plain }

try RuneApp.run(spec)
