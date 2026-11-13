import Foundation
import Rune

public struct LauncherNoteItem: Sendable {
    public var title: String
    public var body: String
}

public let launcherNotes: [LauncherNoteItem] = [
    LauncherNoteItem(title: "Groceries", body: "Oat milk, lemons, basil, sourdough, two avocados."),
    LauncherNoteItem(title: "Trip to Lisbon", body: "Book the tram tour. Pastéis de nata first."),
    LauncherNoteItem(title: "Reading list", body: "The Design of Everyday Things. Thinking in Systems."),
    LauncherNoteItem(title: "Ideas", body: "A launcher that opens notes by typing their first letters."),
]

public struct NotesWindowState: Sendable {
    public var selected: Int = 0
    public var focused: Bool = true
}

public struct LauncherWindowState: Sendable {
    public var query: TextEdit
    public var picked: Int = 0
    public var me: AppHandle<LauncherWindowState>
    public var notes: AppHandle<NotesWindowState>
    public var shownCount: Int = 0
}

public func launcherMatches(_ query: String) -> [Int] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return Array(launcherNotes.indices) }
    return launcherNotes.indices.filter { launcherNotes[$0].title.lowercased().contains(q) }
}

private func openPicked(_ s: inout LauncherWindowState, tx: inout Tx) {
    let found = launcherMatches(s.query.text)
    guard s.picked >= 0 && s.picked < found.count else { return }
    let i = found[s.picked]
    s.notes.update { n, _ in n.selected = i }
    s.notes.focus()
    s.query.clear()
    s.picked = 0
    tx.closeWindow()
}

public func notesWindowView(_ s: NotesWindowState, _ cx: inout Cx<NotesWindowState>, desktop: Bool) -> El<NotesWindowState> {
    let t = Tok.theme(dark: true)
    let accent = Tok.accent(0, dark: true)

    func trafficLight(_ c: Color) -> El<NotesWindowState> {
        el().size(12.0, 12.0).rounded(6.0).bg(s.focused ? c : t.controlOff)
    }

    let titleBar: El<NotesWindowState> = row()
        .h(38.0)
        .px(14.0)
        .gap(8.0)
        .itemsCenter()
        .child(trafficLight(Color(r: 1.0, g: 0.37, b: 0.34, a: 1.0)))
        .child(trafficLight(Color(r: 1.0, g: 0.74, b: 0.18, a: 1.0)))
        .child(trafficLight(Color(r: 0.16, g: 0.79, b: 0.25, a: 1.0)))
        .child(spacer())
        .child(text("Notes").font(Tok.Typography.title).color(t.textSecondary))
        .child(spacer())
        .child(el().w(52.0))

    var list: El<NotesWindowState> = col().key("list").w(170.0).hFull().px(8.0).gap(2.0)
    for (i, item) in launcherNotes.enumerated() {
        let on = i == s.selected
        list = list.child(
            row()
                .key("note-\(i)")
                .h(30.0)
                .px(10.0)
                .rounded(6.0)
                .itemsCenter()
                .bg(on ? accent.alpha(0.85) : Color.transparent)
                .child(text(item.title).font(Tok.Typography.body).color(on ? Color.white : t.text))
                .onClick { state, _ in state.selected = i }
        )
    }

    let chosen = launcherNotes[min(max(0, s.selected), launcherNotes.count - 1)]
    let page: El<NotesWindowState> = col()
        .key("page")
        .grow(1.0)
        .hFull()
        .p(20.0)
        .gap(10.0)
        .bg(t.bg)
        .child(text(chosen.title).font(Tok.Typography.title.lh(22.0)).color(t.text))
        .child(text(chosen.body).font(Tok.Typography.body.lh(20.0)).color(t.textSecondary).wrapText())
        .child(spacer())
        .child(text("⌘Space to search").font(Tok.Typography.label).color(t.textSecondary.alpha(0.7)))

    return col()
        .wFull()
        .hFull()
        .bg(t.card)
        .child(desktop ? titleBar : el().h(12.0))
        .child(row().wFull().grow(1.0).child(list).child(page))
}

public func launcherPanelView(_ s: LauncherWindowState, _ cx: inout Cx<LauncherWindowState>) -> El<LauncherWindowState> {
    let t = Tok.theme(dark: true)
    let accent = Tok.accent(0, dark: true)
    let found = launcherMatches(s.query.text)

    let field: El<LauncherWindowState> = Rune.textInput(key: "query", \.query)
        .font(Tok.Typography.body.lh(26.0))
        .grow(1.0)
        .color(t.text)
        .placeholder("Search notes", color: t.textSecondary)
        .onKey { state, ev, tx in
            let n = launcherMatches(state.query.text).count
            switch ev.key {
            case .arrowDown where n > 0:
                state.picked = (state.picked + 1) % n
                return true
            case .arrowUp where n > 0:
                state.picked = (state.picked + n - 1) % n
                return true
            case .escape:
                tx.closeWindow()
                return true
            default:
                return false
            }
        }
        .onChange { state, _, _ in state.picked = 0 }
        .onSubmit { state, _, tx in openPicked(&state, tx: &tx) }

    var panel: El<LauncherWindowState> = col()
        .key("panel")
        .wFull()
        .rounded(14.0)
        .clip(true)
        .bg(t.card)
        .border(1.0, Color.white.alpha(0.1))
        .child(
            row()
                .h(56.0)
                .px(18.0)
                .gap(12.0)
                .itemsCenter()
                .child(text("⌕").font(Tok.Typography.title.lh(26.0)).color(t.textSecondary))
                .child(field)
        )

    if !found.isEmpty {
        var results: El<LauncherWindowState> = col().key("results").p(6.0).gap(2.0)
        for (rowIdx, noteIdx) in found.enumerated() {
            let on = rowIdx == s.picked
            results = results.child(
                row()
                    .key("result-\(noteIdx)")
                    .h(36.0)
                    .px(12.0)
                    .rounded(8.0)
                    .itemsCenter()
                    .bg(on ? accent.alpha(0.85) : Color.transparent)
                    .child(text(launcherNotes[noteIdx].title).font(Tok.Typography.body).color(on ? Color.white : t.text))
            )
        }
        panel = panel
            .child(el().h(1.0).wFull().bg(t.separator))
            .child(results)
    }

    return col().wFull().hFull().child(panel)
}

public func launcherMenuBarView(_ s: (), _ cx: inout Cx<()>) -> El<()> {
    let ink = Color.white.alpha(0.92)
    func item(_ s: String) -> El<()> { text(s).font(Tok.Typography.body).color(ink) }
    return row()
        .wFull()
        .hFull()
        .px(14.0)
        .gap(18.0)
        .itemsCenter()
        .bg(Color.black.alpha(0.22))
        .child(text("◆").font(Tok.Typography.title).color(ink))
        .child(text("Notes").font(Tok.Typography.title).color(ink))
        .child(item("File"))
        .child(item("Edit"))
        .child(item("View"))
        .child(item("Window"))
        .child(spacer())
        .child(item("Sat 9:41"))
}

@main
public enum RuneLauncherApp {
    public static func makeWindows(
        desktop: Bool = CommandLine.arguments.contains("--desktop"),
        displays: [DisplayInfo] = systemDisplays()
    ) -> [AnyWindowSpec] {
        let notes = App<NotesWindowState>(
            "Notes",
            size: Vec2(520.0, 320.0),
            init: { NotesWindowState(selected: 0, focused: true) },
            view: { s, cx in notesWindowView(s, &cx, desktop: desktop) }
        )
        .keepRunning()
        .onFocus { s, focused, _ in s.focused = focused }

        let notesHandle = notes.handle()
        let placeholder = App<LauncherWindowState>(
            "Launcher",
            size: Vec2(560.0, 220.0),
            init: {
                LauncherWindowState(query: TextEdit(""), picked: 0, me: AppHandle<LauncherWindowState>(), notes: notesHandle)
            },
            view: launcherPanelView
        )
        let launcherHandle = placeholder.handle()
        let launcher = placeholder
            .windowless()
            .initState {
                var query = TextEdit("")
                query.setCursor(utf8Offset: 0, extendSelection: false)
                return LauncherWindowState(query: query, picked: 0, me: launcherHandle, notes: notesHandle)
            }
            .globalShortcut("cmd+space", label: "Toggle Launcher") { s, _ in
                s.shownCount += 1
                s.me.place(.primary, .edge(.top, margin: 150.0, align: .center, inset: 0.0))
                s.me.show()
            }
            .onFocus { _, focused, tx in
                if !focused { tx.closeWindow() }
            }

        var windows: [AnyWindowSpec] = [
            AppWindowSpec.fromApp(notes, key: "notes").boxed(),
            AppWindowSpec.fromApp(launcher, key: "launcher")
                .configuredOptions(WindowOptions.launcherPanel())
                .boxed(),
        ]

        if desktop, let d = displays.first(where: \.primary) ?? displays.first {
            let barOpts = WindowOptions(
                minSize: Vec2(0.0, 0.0),
                transparent: true,
                alwaysOnTop: true,
                borderless: true,
                clickThrough: true,
                position: d.position,
                physicalSize: (d.size.0, UInt32((24.0 * d.scale).rounded()))
            )
            let menuBar = App<()>("Menu bar", size: Vec2(0.0, 24.0), init: { () }, view: launcherMenuBarView)
            windows.append(
                AppWindowSpec.fromApp(menuBar, key: "menu-bar")
                    .configuredOptions(barOpts.macos(MacWindowOptions(shadow: false)))
                    .boxed()
            )
        }

        return windows
    }

    public static func main() throws {
        let desktop = CommandLine.arguments.contains("--desktop")
        try runWindows { displays in
            makeWindows(desktop: desktop, displays: displays)
        }
    }
}
