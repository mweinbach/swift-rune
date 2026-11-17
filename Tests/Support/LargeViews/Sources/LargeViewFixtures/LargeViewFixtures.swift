import Rune
import RuneKit

struct BenchFile {
    var id: String
    var name: String
    var size: UInt64
}

public struct LargeTableState {
    var files: [BenchFile]
    public var table: TableState
    var sorts: [(String, SortDir)] = []
    var opened: [String] = []

    public init() {
        self.files = (0..<100_000).map { i in
            BenchFile(
                id: "f\(i)",
                name: "file \(i) with a name long enough to cut short.rs",
                size: UInt64((i * 7919) % 100_000)
            )
        }
        self.table = TableState().multiSelect(true)
    }
}

public struct LargeTreeState {
    public var files: TreeModel<FileNode<(UInt32, UInt32)>>
}

public enum LargeViewFixtures {
    public static let tableViewport = Vec2(900, 900)
    public static let treeViewport = Vec2(360, 900)

    public static func table(_ app: LargeTableState) -> Runtime<LargeTableState> {
        return Runtime(state: app, viewport: tableViewport, pixelScale: 2.0, systemDark: true) { s, cx in
            let kit = Kit.neutral(dark: true)
            return col().size(900.0, 900.0).child(
                TableView<LargeTableState>(
                    \.table,
                    len: { $0.files.count },
                    rowID: { $0.files[$1].id }
                )
                .name("Files")
                .column(TableCol("name", "Name").flex(1.0).min(120.0).sortable())
                .column(TableCol("size", "Size").width(100.0).min(60.0).max(180.0).align(.end).sortable())
                .column(TableCol("kind", "Kind").width(80.0).resizable(false))
                .cell { s, i, colId in
                    switch colId {
                    case "name": return .text(s.files[i].name)
                    case "size": return .text("\(s.files[i].size)").mono()
                    default: return .text("Rust").muted()
                    }
                }
                .onSort { s, colId, dir, _ in
                    s.sorts.append((colId, dir))
                    if colId == "size" {
                        s.files.sort {
                            if dir == .ascending { return $0.size < $1.size }
                            return $0.size > $1.size
                        }
                    }
                }
                .onOpen { s, id, _ in s.opened.append(id) }
                .zebra(true)
                .build(s, cx: cx, kit: kit)
                .h(900.0)
            )
        }
    }

    public static func treeModel() -> TreeModel<FileNode<(UInt32, UInt32)>> {
        var paths: [(String, (UInt32, UInt32))] = []
        paths.reserveCapacity(50_000)
        for d in 0..<500 {
            for f in 0..<100 {
                paths.append(("pkg\(d)/file\(f).rs", (1, 0)))
            }
        }
        var model = FileTree().build(paths)
        model.expandAll()
        return model
    }

    public static func tree(_ model: TreeModel<FileNode<(UInt32, UInt32)>>) -> Runtime<LargeTreeState> {
        Runtime(state: LargeTreeState(files: model), viewport: treeViewport, pixelScale: 2, systemDark: true) { state, cx in
            col().wFull().hFull().child(
                Tree(\LargeTreeState.files, label: { $0.name })
                    .row { node, row in
                        TreeRowItem.file(node, row: row).changes(added: node.data?.0 ?? 0, removed: node.data?.1 ?? 0)
                    }
                    .build(state, cx: cx, kit: Kit.neutral(dark: true))
                    .grow(1).minH(0)
            )
        }
    }
}
