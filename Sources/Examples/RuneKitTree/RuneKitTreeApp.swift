import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/tree.rs`:
/// a repository's changed files as a tree with a filter field, change counts, and detail view.
@main
enum RuneKitTreeApp {
    enum Status: Sendable, Equatable {
        case added
        case modified
        case deleted
    }

    struct Change: Sendable, Equatable {
        var added: UInt32
        var removed: UInt32
        var status: Status
    }

    struct State: Sendable {
        var files: TreeModel<FileNode<Change>>
        var query: TextEdit = TextEdit("")
    }

    static let repoEntries: [(String, UInt32, UInt32, Status)] = [
        ("crates/rune/src/el.rs", 48, 0, .modified),
        ("crates/rune/src/focus.rs", 2, 1, .modified),
        ("crates/rune/src/runtime.rs", 43, 2, .modified),
        ("crates/rune/src/tooling.rs", 9, 0, .modified),
        ("crates/rune/src/on_key_tests.rs", 212, 0, .added),
        ("crates/rune-kit/src/lib.rs", 4, 0, .modified),
        ("crates/rune-kit/src/glyphs.rs", 44, 0, .modified),
        ("crates/rune-kit/src/tree.rs", 1140, 0, .added),
        ("crates/rune-kit/src/table.rs", 780, 0, .added),
        ("crates/rune-kit/src/list_old.rs", 0, 96, .deleted),
        ("crates/rune-kit/examples/tree.rs", 120, 0, .added),
        ("crates/rune-kit/examples/table.rs", 110, 0, .added),
        ("crates/rune-kit/tests/tree.rs", 290, 0, .added),
        ("crates/rune-kit/tests/table.rs", 230, 0, .added),
        ("crates/rune-kit/tests/glyphs.rs", 7, 1, .modified),
        ("demo/kit/tree-dark.png", 0, 0, .added),
        ("demo/kit/tree-light.png", 0, 0, .added),
        ("site/src/content/docs/kit/tree.md", 64, 0, .added),
        ("CHANGELOG.md", 12, 0, .modified),
        ("README.md", 18, 3, .modified),
    ]

    static func initialState(big: Bool = false) -> State {
        let entries: [(path: String, change: Change)]
        if big {
            var out: [(path: String, change: Change)] = []
            out.reserveCapacity(50_000)
            for d in 0..<500 {
                for f in 0..<100 {
                    let i = UInt32(d * 100 + f)
                    out.append((
                        String(format: "pkg%03d/src/module%d.rs", d, f),
                        Change(added: i % 37, removed: i % 11, status: .modified)
                    ))
                }
            }
            entries = out
        } else {
            entries = repoEntries.map { ($0.0, Change(added: $0.1, removed: $0.2, status: $0.3)) }
        }

        var files = FileTree().build(entries)
        files.expandAll()
        if !big {
            files.setExpanded("demo/kit", false)
            files.select("crates/rune-kit/src/tree.rs")
        }
        return State(files: files)
    }

    static func totals(for id: String, state: State) -> (isFolder: Bool, added: UInt32, removed: UInt32) {
        let totals = state.files.subtree(of: id).reduce(into: (added: UInt32(0), removed: UInt32(0))) { sum, node in
            if let change = node.data {
                sum.added += change.added
                sum.removed += change.removed
            }
        }
        return (state.files.get(id)?.isDirectory == true, totals.added, totals.removed)
    }

    static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let k = Kit.neutral(dark: cx.systemDark)
        let query = s.query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let treeEl = Tree(\State.files, label: { $0.name })
            .name("Changed files")
            .row { node, row in
                var item = TreeRowItem<State>.file(node, row: row).highlight(query)
                guard let change = node.data else { return item }
                let color: Color, letter: String
                switch change.status {
                case .added:
                    (color, letter) = (k.c.success.icon, "A")
                case .modified:
                    (color, letter) = (k.c.warning.icon, "M")
                case .deleted:
                    (color, letter) = (k.c.danger.icon, "D")
                    item = item.labelColor(k.c.textFaint)
                }
                return item.changes(added: change.added, removed: change.removed)
                    .trailing(text(letter).key("status").font(k.ty.textXsmallMedium).color(color).w(10))
            }
            .build(s, cx: cx, kit: k)
            .grow(1)
            .minH(0)

        let filter = TextInput(key: "filter", \State.query)
            .placeholder("Filter files")
            .leadingIcon(KitIcons.search)
            .clearButton()
            .onChange { state, value, _ in
                let q = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if q.isEmpty {
                    state.files.clearFilter()
                } else {
                    state.files.filter { $0.name.lowercased().contains(q) }
                }
            }
            .build(k)

        let sidebar: El<State> = col()
            .key("sidebar")
            .w(300)
            .hFull()
            .p(8)
            .gap(8)
            .bg(k.c.bgBase)
            .child(filter)
            .child(treeEl)

        let detailContent: El<State>
        if let id = s.files.cursorID {
            let info = totals(for: id, state: s)
            detailContent = col()
                .gap(6)
                .child(text(id).font(k.ty.uiMedium).color(k.c.textBase))
                .child(
                    text("\(info.isFolder ? "Folder" : "File") · +\(info.added) \u{2212}\(info.removed)")
                        .font(k.ty.textSmall)
                        .color(k.c.textMuted)
                )
        } else {
            detailContent = col().child(text("Select a file").font(k.ty.ui).color(k.c.textMuted))
        }

        return row()
            .wFull()
            .hFull()
            .bg(k.c.page)
            .child(sidebar)
            .child(col().key("detail").grow(1).hFull().p(20).child(detailContent))
    }

    static func makeApp(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> App<State> {
        let big = arguments.contains("--big")
        return App(title: "Tree", size: Vec2(720, 480), state: initialState(big: big), view: view)
    }

    static func main() throws {
        try makeApp().run()
    }
}
