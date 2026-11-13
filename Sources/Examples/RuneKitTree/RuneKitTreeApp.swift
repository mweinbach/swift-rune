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
        var added: Int
        var removed: Int
        var status: Status
    }

    struct State: Sendable {
        var entries: [(path: String, change: Change)]
        var byPath: [String: Change]
        var expanded: Set<String>
        var selected: String?
        var query: TextEdit = TextEdit("")
    }

    static let repoEntries: [(String, Int, Int, Status)] = [
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
                    let i = d * 100 + f
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

        var byPath: [String: Change] = [:]
        for entry in entries {
            byPath[entry.path] = entry.change
        }

        var expanded: Set<String> = []
        if !big {
            let roots = FileTreeBuilder(compactFolders: true).buildTreeItems(entries.map { ($0.path, $0.change) })
            func collectDirs(_ items: [TreeItem<String>]) {
                for item in items where item.isFolder {
                    if item.id != "demo/kit" {
                        expanded.insert(item.id)
                    }
                    collectDirs(item.children)
                }
            }
            collectDirs(roots)
        }

        return State(
            entries: entries,
            byPath: byPath,
            expanded: expanded,
            selected: big ? nil : "crates/rune-kit/src/tree.rs",
            query: TextEdit("")
        )
    }

    static func totals(for id: String, state: State) -> (isFolder: Bool, added: Int, removed: Int) {
        if let ch = state.byPath[id] {
            return (false, ch.added, ch.removed)
        }
        let prefix = id.hasSuffix("/") ? id : "\(id)/"
        var added = 0
        var removed = 0
        for (path, ch) in state.byPath where path.hasPrefix(prefix) {
            added += ch.added
            removed += ch.removed
        }
        return (true, added, removed)
    }

    static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let k = Kit.neutral(dark: cx.systemDark)
        let q = s.query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty
            ? s.entries
            : s.entries.filter {
                let name = ($0.path as NSString).lastPathComponent.lowercased()
                return name.contains(q)
            }

        var effectiveExpanded = s.expanded
        let roots = FileTreeBuilder(compactFolders: true).buildTreeItems(filtered.map { ($0.path, $0.change) })
        if !q.isEmpty {
            func expandMatches(_ items: [TreeItem<String>]) {
                for item in items where item.isFolder {
                    effectiveExpanded.insert(item.id)
                    expandMatches(item.children)
                }
            }
            expandMatches(roots)
        }

        let treeEl: El<State> = k.tree(
            key: "files",
            roots: roots,
            expanded: effectiveExpanded,
            selected: s.selected,
            onToggleExpand: { state, id in
                if state.expanded.contains(id) {
                    state.expanded.remove(id)
                } else {
                    state.expanded.insert(id)
                }
            },
            onSelect: { state, id in
                state.selected = id
            }
        )
        .grow(1)
        .minH(0)
        .scrollY()

        let filter: El<State> = k.textInputField(
            key: "filter",
            \State.query,
            placeholder: "Filter files",
            leadingIcon: KitIcons.search
        )

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
        if let id = s.selected {
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
