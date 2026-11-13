import Foundation
import OpenCodeTheme
import Rune
import RuneKit
import RuneMotion

public struct DemoTab: Sendable {
    public var id: String
    public var title: String
    public var project: Int
    public var status: TabItemStatus?
    public var draft: Bool
    public var pinned: Bool
}

public struct TabStripExampleState: Sendable {
    public var tabs: [DemoTab]
    public var active: String?
    public var top: TabDragState
    public var side: TabDragState
    public var demo: [TabDragState]
    public var next: Int
    public var note: String
}

private let tabProjects: [(String, String)] = [
    ("acme-web", "gray"),
    ("tally", "orange"),
    ("notes", "blue"),
    ("rune", "green"),
    ("site", "purple"),
]

private let tabTitles: [String] = [
    "Formatting tour",
    "Fix price formatting",
    "Profile the frame loop",
    "Port the settings pane",
    "Theme tokens for dark mode",
    "Spring presets for sheets",
    "Draft the changelog",
    "Window restoration bug",
    "Keyboard navigation audit",
    "Sidebar resize behaviour",
    "Scroll jank in the list",
    "Snap layouts on Windows",
]

private func makeDemoTab(_ i: Int) -> DemoTab {
    let status: TabItemStatus?
    switch i % 7 {
    case 1: status = .spinner
    case 3: status = .dirty
    case 4: status = .badge("!", tone: .warning)
    case 6: status = .badge("×", tone: .danger)
    default: status = nil
    }
    return DemoTab(
        id: "s\(i)",
        title: tabTitles[i % tabTitles.count],
        project: i % tabProjects.count,
        status: status,
        draft: false,
        pinned: false
    )
}

public func withDemoTabs(count: Int, active: Int) -> TabStripExampleState {
    var tabs = (0..<count).map(makeDemoTab)
    if tabs.count > 5 {
        tabs[5].draft = true
        tabs[5].status = nil
    }
    let activeId = tabs.indices.contains(active) ? tabs[active].id : nil
    return TabStripExampleState(
        tabs: tabs,
        active: activeId,
        top: TabDragState(),
        side: TabDragState(),
        demo: [TabDragState(), TabDragState(), TabDragState()],
        next: count,
        note: ""
    )
}

public func initialTabStripExampleState() -> TabStripExampleState {
    withDemoTabs(count: 8, active: 0)
}

private func selectTab(_ s: inout TabStripExampleState, id: String, _: inout Tx) {
    s.active = id
}

private func closeTab(_ s: inout TabStripExampleState, id: String, _: inout Tx) {
    guard let i = s.tabs.firstIndex(where: { $0.id == id }) else { return }
    s.tabs.remove(at: i)
    if s.active == id {
        if s.tabs.isEmpty {
            s.active = nil
        } else {
            s.active = s.tabs[min(i, s.tabs.count - 1)].id
        }
    }
}

private func reorderTab(_ s: inout TabStripExampleState, r: TabReorder, _: inout Tx) {
    guard s.tabs.indices.contains(r.from), s.tabs.indices.contains(r.to) else { return }
    let t = s.tabs.remove(at: r.from)
    s.tabs.insert(t, at: r.to)
}

private func tearOutTab(_ s: inout TabStripExampleState, t: TabTearOut, _: inout Tx) {
    let title = s.tabs.indices.contains(t.index) ? s.tabs[t.index].title : ""
    s.note = String(format: "Torn out: \u{201c}%@\u{201d}, dropped at %.0f, %.0f", title, t.windowPoint.x, t.windowPoint.y)
}

private func newTab(_ s: inout TabStripExampleState, _: inout Tx) {
    let id = "d\(s.next)"
    s.next += 1
    s.tabs.append(DemoTab(id: id, title: "New session", project: 0, status: nil, draft: true, pinned: false))
    s.active = id
}

private func projectAvatar(name: String, variant: String, k: Kit) -> El<TabStripExampleState> {
    let theme = OpenCodeTheme.theme(dark: k.dark)
    let initial = String((name.first ?? " ").uppercased())
    let style = TextStyle(size: 11.0, weight: 530.0).lh(11.0).letterSpacing(0.05)
    return row()
        .size(16.0, 16.0)
        .rounded(4.0)
        .center()
        .bg(theme.color("v2-avatar-bg-\(variant)"))
        .gradient(theme.color("v2-alpha-light-16"), Color.transparent)
        .border(0.5, theme.color("v2-avatar-border-\(variant)"))
        .child(text(initial).font(style).color(theme.color("v2-avatar-fg")))
}

private func stripItems(_ s: TabStripExampleState, k: Kit) -> [StripTabItem<TabStripExampleState>] {
    s.tabs.map { t in
        let (project, variant) = tabProjects[t.project]
        let active = s.active == t.id
        let effectiveStatus: TabItemStatus
        if let st = t.status, (!active || st == .spinner) {
            effectiveStatus = st
        } else {
            effectiveStatus = .none
        }
        var item = StripTabItem<TabStripExampleState>(id: t.id, title: t.title)
            .status(effectiveStatus)
            .pinned(t.pinned)
        if t.draft {
            item = item.icon(OpenCodeIcons.edit)
        } else {
            item = item.avatar(projectAvatar(name: project, variant: variant, k: k))
        }
        return item
    }
}

private func buildTitlebar(_ s: TabStripExampleState, cx: inout Cx<TabStripExampleState>, k: Kit) -> El<TabStripExampleState> {
    func nav(_ svg: SVGIcon, key: String, label: String) -> El<TabStripExampleState> {
        k.iconButton(key: key, svg: svg, label: label, size: .lg, variant: .ghost) { _, _ in }.w(36.0)
    }
    let plus = k.iconButton(
        key: "new-tab",
        svg: OpenCodeNewIcons.plus,
        label: "New session",
        size: .lg,
        variant: .ghost,
        onClick: newTab
    )
    var stripBuilder = TabStrip<TabStripExampleState>(key: "top", orientation: .horizontal)
        .tabs(stripItems(s, k: k))
        .active(s.active)
        .dragState(\.top, current: s.top)
        .tearOut(TearOutSpec())
        .closeIcon(OpenCodeIcons.xmarkSmall)
        .trailing(plus)
        .onSelect(selectTab)
        .onClose(closeTab)
        .onReorder(reorderTab)
        .onTearOut(tearOutTab)
    if let topSize = cx.layoutSize(of: "top") {
        stripBuilder = stripBuilder.availableWidth(topSize.x)
    }
    let strip = stripBuilder.buildLayered(s, kit: k, elevateDragged: true)

    return WindowTitlebar<TabStripExampleState>.fromInsets(cx.chromeInsets())
        .leading(
            row()
                .key("nav")
                .gap(2.0)
                .itemsCenter()
                .child(nav(OpenCodeIcons.gridPlus, key: "nav-home", label: "Home"))
                .child(nav(OpenCodeIcons.magnifyingGlass, key: "nav-search", label: "Search sessions"))
        )
        .tabs(strip)
        .build(k)
}

private func buildSidebar(_ s: TabStripExampleState, k: Kit) -> El<TabStripExampleState> {
    let strip = TabStrip<TabStripExampleState>(key: "side", orientation: .vertical)
        .tabs(stripItems(s, k: k))
        .active(s.active)
        .dragState(\.side, current: s.side)
        .closeIcon(OpenCodeIcons.xmarkSmall)
        .onSelect(selectTab)
        .onClose(closeTab)
        .onReorder(reorderTab)
        .build(s, kit: k)
    return col()
        .key("sidebar")
        .w(240.0)
        .hFull()
        .minH(0.0)
        .pl(11.0)
        .pr(3.0)
        .pb(10.0)
        .child(strip)
}

private func sampleStrip(
    _ s: TabStripExampleState,
    k: Kit,
    index: Int,
    width: Float,
    label: String
) -> El<TabStripExampleState> {
    let keyPath: WritableKeyPath<TabStripExampleState, TabDragState>
    switch index {
    case 0: keyPath = \.demo[0]
    case 1: keyPath = \.demo[1]
    default: keyPath = \.demo[2]
    }
    let strip = TabStrip<TabStripExampleState>(key: "sample-\(index)", orientation: .horizontal)
        .tabs(Array(stripItems(s, k: k).prefix(8)))
        .active(s.active)
        .availableWidth(width)
        .dragState(keyPath, current: s.demo[index])
        .closeIcon(OpenCodeIcons.xmarkSmall)
        .onSelect(selectTab)
        .build(s, kit: k)
    return col()
        .gap(6.0)
        .child(text(label).font(k.ty.textXsmallMedium).color(k.c.textMuted))
        .child(
            row()
                .w(width + 16.0)
                .h(44.0)
                .px(8.0)
                .itemsCenter()
                .rounded(8.0)
                .bg(k.c.bgDeep)
                .child(strip)
        )
}

private func buildCard(_ s: TabStripExampleState, k: Kit) -> El<TabStripExampleState> {
    let title = s.tabs.first(where: { $0.id == s.active })?.title ?? "No tab"
    let more = k.button(key: "add-many", "Add 12 tabs", variant: .neutral) { (state: inout TabStripExampleState, _) in
        for _ in 0..<12 {
            var t = makeDemoTab(state.next)
            state.next += 1
            t.id = "x\(state.next)"
            state.tabs.append(t)
        }
    }
    let reset = k.button(key: "reset", "Reset", variant: .ghost) { (state: inout TabStripExampleState, _) in
        state = initialTabStripExampleState()
    }
    return col()
        .key("card")
        .grow(1.0)
        .hFull()
        .minW(0.0)
        .ml(8.0)
        .mr(8.0)
        .mb(8.0)
        .mt(1.0)
        .rounded(10.0)
        .bg(k.c.bgBase)
        .p(24.0)
        .gap(20.0)
        .child(text(title).key("heading").font(k.ty.bodyMedium).color(k.c.textBase).motionIntent(.cut))
        .child(
            row()
                .gap(8.0)
                .child(more)
                .child(reset)
                .child(text(s.note).key("note").font(k.ty.ui).color(k.c.textMuted))
        )
        .child(sampleStrip(s, k: k, index: 0, width: 720.0, label: "Full (over 64 points)"))
        .child(sampleStrip(s, k: k, index: 1, width: 470.0, label: "Compact (44 to 64 points)"))
        .child(sampleStrip(s, k: k, index: 2, width: 290.0, label: "Icon only (44 points or less)"))
}

public func tabStripExampleView(
    _ s: TabStripExampleState,
    _ cx: inout Cx<TabStripExampleState>
) -> El<TabStripExampleState> {
    let k = OpenCodeTheme.kit(dark: cx.systemDark)
    let bar = buildTitlebar(s, cx: &cx, k: k)
    return RuneKit.root(
        col()
            .key("window")
            .sizeFull()
            .bg(k.c.bgDeep)
            .child(bar)
            .child(
                row()
                    .key("body")
                    .wFull()
                    .grow(1.0)
                    .minH(0.0)
                    .child(buildSidebar(s, k: k))
                    .child(buildCard(s, k: k))
            ),
        []
    )
}

@main
public enum RuneKitTabStripApp {
    public static func makeApp() -> App<TabStripExampleState> {
        App("Tab strip", size: Vec2(1280, 800), init: { initialTabStripExampleState() }, view: tabStripExampleView)
            .scene("tabs") { s, _ in s = initialTabStripExampleState() }
            .scene("overflow") { s, _ in s = withDemoTabs(count: 40, active: 2) }
            .scene("single") { s, _ in s = withDemoTabs(count: 1, active: 0) }
            .titlebar(Titlebar(height: 44.0))
    }

    public static func main() throws {
        try makeApp().run()
    }
}
