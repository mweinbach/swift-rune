import Foundation
import Rune
import RuneKit
import RuneMotion

private let homeIcon = SVGIcon(
    viewBox: 16.0,
    paths: ["M3 7L8 3L13 7V12.5H9.5V9.5H6.5V12.5H3Z"],
    strokeWidth: 1.2,
    body: #"<path d="M3 7L8 3L13 7V12.5H9.5V9.5H6.5V12.5H3Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" fill="none"/>"#
)
private let plusIcon = SVGIcon(
    viewBox: 16.0,
    paths: ["M8 3.5V12.5M3.5 8H12.5"],
    strokeWidth: 1.2,
    body: #"<path d="M8 3.5V12.5M3.5 8H12.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#
)
private let searchIcon = SVGIcon(
    viewBox: 16.0,
    paths: ["M10 10L12.75 12.75"],
    strokeWidth: 1.2,
    body: #"<circle cx="7" cy="7" r="3.75" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M10 10L12.75 12.75" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#
)
private let slidersIcon = SVGIcon(
    viewBox: 16.0,
    paths: ["M3 5H13M3 11H13"],
    strokeWidth: 1.2,
    body: #"<path d="M3 5H13M3 11H13" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="6" cy="5" r="1.6" fill="currentColor"/><circle cx="10.5" cy="11" r="1.6" fill="currentColor"/>"#
)

private let rowHeightConst: Float = 45.0
private let rowGapConst: Float = 4.0

public enum SessionStatus: Sendable, Equatable {
    case idle
    case busy
    case attention
    case unread
}

public struct ShellSession: Sendable {
    public var id: String
    public var title: String
    public var project: Int
    public var status: SessionStatus
}

private let shellProjects: [(String, Float)] = [
    ("rune", 250.0),
    ("site", 150.0),
    ("motion", 30.0),
    ("notes", 320.0),
]

public struct ShellExampleState: Sendable {
    public var sidebar: PaneState
    public var inspector: PaneState
    public var sessions: [ShellSession]
    public var reorder: Reorder<String>
    public var selected: String
    public var renaming: String?
    public var rename: TextEdit
    public var virtualised: Bool
    public var page: Bool
    public var pagePair: Bool
}

public func initialShellExampleState(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> ShellExampleState {
    let virtualised = arguments.contains("virtual") || arguments.contains("--virtual")
    let page = arguments.contains("page") || arguments.contains("--page")
    let pagePair = arguments.contains("page-pair") || arguments.contains("--page-pair")
    let sessions: [ShellSession]
    if virtualised {
        sessions = (0..<5000).map { i in
            ShellSession(id: "v\(i)", title: "Session \(5000 - i)", project: i % 4, status: .idle)
        }
    } else {
        sessions = [
            ShellSession(id: "s1", title: "Fix scroll jank in the list", project: 0, status: .busy),
            ShellSession(id: "s2", title: "Profile the frame loop", project: 0, status: .attention),
            ShellSession(id: "s3", title: "Port the settings pane", project: 1, status: .unread),
            ShellSession(id: "s4", title: "Sidebar resize behaviour", project: 0, status: .idle),
            ShellSession(id: "s5", title: "Theme tokens for dark mode", project: 1, status: .idle),
            ShellSession(id: "s6", title: "Spring presets for sheets", project: 2, status: .unread),
            ShellSession(id: "s7", title: "Draft the changelog", project: 3, status: .idle),
            ShellSession(id: "s8", title: "Window restoration bug", project: 0, status: .idle),
            ShellSession(id: "s9", title: "Keyboard navigation audit", project: 1, status: .idle),
        ]
    }
    return ShellExampleState(
        sidebar: PaneState(width: 276.0).range(136.0, 640.0),
        inspector: PaneState(width: 280.0).range(220.0, 420.0).collapsed(),
        sessions: sessions,
        reorder: Reorder<String>().gap(virtualised ? 0.0 : rowGapConst),
        selected: sessions[0].id,
        renaming: nil,
        rename: TextEdit(""),
        virtualised: virtualised,
        page: page,
        pagePair: pagePair
    )
}

private func sessionAvatar(_ name: String, hue: Float, k: Kit) -> El<ShellExampleState> {
    let initial = String((name.first ?? " ").uppercased())
    return row()
        .size(16.0, 16.0)
        .rounded(4.0)
        .center()
        .bg(Color.oklch(0.62, 0.12, hue))
        .child(text(initial).font(k.ty.smallMedium).color(.white))
}

private func sessionRow(_ s: ShellExampleState, index i: Int, k: Kit) -> El<ShellExampleState> {
    let session = s.sessions[i]
    let (project, hue) = shellProjects[session.project]
    let id = session.id

    var r = SidebarRow<ShellExampleState>(key: id, title: session.title)
        .height(rowHeightConst)
        .avatar(sessionAvatar(project, hue: hue, k: k))
        .subtitle(project)
        .selected(s.selected == id)
        .onClick { state, _ in
            state.selected = id
        }
        .onClose { state, _ in
            state.sessions.removeAll { $0.id == id }
        }
        .onDoubleClick { state, _ in
            let title = state.sessions.first(where: { $0.id == id })?.title ?? ""
            var ed = TextEdit(title)
            ed.selectAll()
            state.rename = ed
            state.renaming = id
        }
        .reorder(\.reorder, id: id, index: i, count: s.sessions.count) { state, from, to in
            guard state.sessions.indices.contains(from), state.sessions.indices.contains(to) else { return }
            let item = state.sessions.remove(at: from)
            state.sessions.insert(item, at: to)
        }
        .reorderState(s.reorder, id: id, index: i)

    switch session.status {
    case .busy: r = r.status(.spinner())
    case .attention: r = r.status(.dot(k.c.warning.icon))
    case .unread: r = r.status(.dot(k.c.info.icon))
    case .idle: break
    }

    if s.renaming == id {
        r = r.renaming(
            \ShellExampleState.rename,
            onCommit: { state, _, _ in
                let targetId = state.renaming
                state.renaming = nil
                let trimmed = state.rename.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let idx = state.sessions.firstIndex(where: { $0.id == targetId }) {
                    state.sessions[idx].title = trimmed
                }
            },
            onCancel: { state, _ in
                state.renaming = nil
            }
        )
    }
    return r.build(k)
}

private func buildSidebar(_ s: ShellExampleState, k: Kit) -> El<ShellExampleState> {
    let sb = Sidebar<ShellExampleState>()
        .label("Sessions")
        .inset(0.0)
        .headerGap(4.0)
        .headerPadding(top: 0.0, bottom: 16.0)
        .rowGap(rowGapConst)
        .header(
            col()
                .gap(4.0)
                .child(SidebarRow<ShellExampleState>(key: "home", title: "Home").icon(homeIcon).height(32.0).build(k))
                .child(SidebarRow<ShellExampleState>(key: "search", title: "Search").icon(searchIcon).subtitle("⌘K").height(32.0).build(k))
                .child(SidebarRow<ShellExampleState>(key: "new", title: "New session").icon(plusIcon).subtitle("⌘N").height(32.0).build(k))
        )
        .footer(
            SidebarRow<ShellExampleState>(key: "settings", title: "Settings")
                .icon(slidersIcon)
                .height(32.0)
                .onClick { state, _ in
                    state.page = true
                }
                .build(k)
        )
    if s.virtualised {
        return sb.rowHeight(rowHeightConst)
            .virtualRows(
                count: s.sessions.count,
                key: { state, i in state.sessions[i].id },
                build: { state, i in sessionRow(state, index: i, k: k) }
            )
            .build(k)
    }
    let rows = (0..<s.sessions.count).map { sessionRow(s, index: $0, k: k) }
    return sb.sections(rows).build(k)
}

private func settingsPage(dark: Bool, inset: Float) -> El<ShellExampleState> {
    let k = Kit.neutral(dark: dark)
    func settingRow(_ title: String, _ desc: String, _ on: Bool, key: String) -> El<ShellExampleState> {
        row()
            .wFull()
            .py(12.0)
            .px(16.0)
            .rounded(k.radius.md)
            .bg(k.c.layer01)
            .border(1.0, k.c.borderWeak)
            .itemsCenter()
            .justifyBetween()
            .child(
                col()
                    .gap(2.0)
                    .child(text(title).font(k.ty.uiMedium).color(k.c.textBase))
                    .child(text(desc).font(k.ty.small).color(k.c.textMuted))
            )
            .child(Switch<ShellExampleState>(checked: on).build(k, key: key))
    }

    let body = col()
        .key("settings-body")
        .sizeFull()
        .p(24.0)
        .itemsCenter()
        .child(
            col()
                .wFull()
                .maxW(520.0)
                .gap(12.0)
                .child(text("Workspace Settings").font(k.ty.bodyMedium).color(k.c.textBase))
                .child(settingRow("Unlock with Touch ID", "Prompt for biometrics when returning after idle", true, key: "sw-touch"))
                .child(settingRow("Clear clipboard automatically", "Remove copied secrets after 30 seconds", true, key: "sw-clip"))
                .child(settingRow("Show sidebar unread badges", "Highlight active background tasks in the toggle", false, key: "sw-unread"))
        )

    let back = k.button(key: "back", "Back", variant: .ghost, size: .regular) { (state: inout ShellExampleState, _) in
        state.page = false
    }
    let lock = IconButton<ShellExampleState>(key: "lock", svg: k.glyph.lock)
        .variant(.ghostMuted)
        .help("Lock")
        .shortcut("⌘L")
        .build(k)

    return Page<ShellExampleState>(content: body)
        .title("Settings")
        .leading(back)
        .trailing(lock)
        .titlebarInset(inset)
        .frameInset(8.0)
        .toolbarInPanel()
        .build(k)
}

public func shellExampleView(_ s: ShellExampleState, _ cx: inout Cx<ShellExampleState>) -> El<ShellExampleState> {
    if s.pagePair {
        return row()
            .sizeFull()
            .child(col().grow(1.0).hFull().child(settingsPage(dark: false, inset: 74.0)))
            .child(col().grow(1.0).hFull().child(settingsPage(dark: true, inset: 74.0)))
    }
    if s.page {
        return settingsPage(dark: cx.systemDark, inset: cx.chromeInsets().top)
    }

    let k = Kit.neutral(dark: cx.systemDark)
    let title = s.sessions.first(where: { $0.id == s.selected })?.title ?? ""

    func buildMain(_ state: ShellExampleState) -> El<ShellExampleState> {
        let activeTitle = state.sessions.first(where: { $0.id == state.selected })?.title ?? ""
        func line(_ t: String, _ ink: Color) -> El<ShellExampleState> {
            text(t).font(k.ty.body).color(ink).wrap(.wrap)
        }
        return col()
            .key("transcript")
            .wFull()
            .p(24.0)
            .gap(14.0)
            .child(text(activeTitle).key("heading").font(k.ty.bodyMedium).color(k.c.textBase))
            .child(line("The list stutters when a long session scrolls past the fold. Frames 40 to 52 spend most of their time laying out rows that never draw.", k.c.textMuted))
            .child(line("Virtualising the rows keeps layout to the viewport and two screens either side, so a commit costs the rows that changed.", k.c.textMuted))
            .child(line("Next: keep the selected row's height when its preview text grows, so the list doesn't jump under the pointer.", k.c.textMuted))
    }

    func buildInspector(_ state: ShellExampleState) -> El<ShellExampleState> {
        func field(_ label: String, _ value: String) -> El<ShellExampleState> {
            col()
                .gap(2.0)
                .child(text(label).font(k.ty.small).color(k.c.textFaint))
                .child(text(value).font(k.ty.ui).color(k.c.textBase))
        }
        return col()
            .key("details")
            .wFull()
            .p(16.0)
            .gap(14.0)
            .child(text("Details").font(k.ty.uiMedium).color(k.c.textBase))
            .child(field("Model", "Neutral 2"))
            .child(field("Branch", "dev"))
            .child(field("Messages", "38"))
            .child(field("Updated", "4 minutes ago"))
    }

    let toolbar = Toolbar<ShellExampleState>()
        .title(title)
        .trailing(
            k.iconButton(
                key: "inspector-toggle",
                svg: KitIcons.inspector,
                label: s.inspector.isOpen ? "Hide inspector" : "Show inspector",
                variant: .ghost
            ) { state, _ in
                state.inspector.toggle()
            }
        )
        .build(k)

    let unread = s.sessions.contains { $0.status == .unread }
    return SplitView<ShellExampleState>(content: buildMain)
        .sidebar(\.sidebar, current: s.sidebar) { state in buildSidebar(state, k: k) }
        .inspector(\.inspector, current: s.inspector, build: buildInspector)
        .toolbar(toolbar)
        .titlebarInset(cx.chromeInsets())
        .frameInset(8.0)
        .toolbarInPanel()
        .sidebarPadding(18.0)
        .sidebarToggle(
            SidebarToggle<ShellExampleState>()
                .size(.lg)
                .pastLights(16.0)
                .edge(18.0)
                .gap(4.0)
                .inHeader()
                .unread(unread)
        )
        .paneMotion(
            PaneMotion()
                .spring(Spring(duration: 0.3, bounce: 0.0))
                .scaleWithWidth(reference: 480.0, min: 0.15, max: 0.3)
                .fadeTail(0.15)
        )
        .sidebarPeek(
            SidebarPeek()
                .edge(16.0, delay: 0.04)
                .toggleDelay(0.08)
                .below(56.0)
                .hold(margin: 15.0, grace: 0.1)
                .spring(Spring(duration: 0.18, bounce: 0.0))
        )
        .reducedMotion(cx.isReducedMotion())
        .build(s, kit: k)
}

public func shellExampleOnKey(_ s: inout ShellExampleState, ev: KeyEvent, _ tx: inout Tx) -> Bool {
    if isSidebarToggle(ev.key, mods: ev.mods) {
        s.sidebar.toggle()
        return true
    }
    if ev.mods.primaryCommand && ev.mods.alt && ev.isCommand("i") {
        s.inspector.toggle()
        return true
    }
    return false
}

@main
public enum RuneKitShellApp {
    public static func makeApp(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> App<ShellExampleState> {
        let chrome = Chrome(fullSizeContent: true, trafficLights: (16.0, 25.0), dragRegions: true)
        return App("Shell", size: Vec2(1040, 640), init: { initialShellExampleState(arguments: arguments) }, view: shellExampleView)
            .onKey(shellExampleOnKey)
            .scene("default") { s, _ in s = initialShellExampleState(arguments: []) }
            .scene("virtual") { s, _ in s = initialShellExampleState(arguments: ["virtual"]) }
            .scene("page") { s, _ in s = initialShellExampleState(arguments: ["page"]) }
            .chrome(chrome)
    }

    public static func main() throws {
        try makeApp().run()
    }
}
