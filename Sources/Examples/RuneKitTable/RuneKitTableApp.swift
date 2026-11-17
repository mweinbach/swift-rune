import Foundation
import Rune
import RuneKit
import RuneMotion

public struct Artifact: Sendable {
    public var id: String
    public var name: String
    public var target: String
    public var size: UInt64
    public var ms: UInt32
    public var cached: Bool
}

public struct TableExampleState: Sendable {
    public var rows: [Artifact]
    public var table: TableState
}

private let targets = [
    "aarch64-apple-darwin",
    "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
    "wasm32-unknown-unknown",
    "aarch64-apple-ios",
]
private let crates = ["rune", "rune-kit", "rune-motion", "rune-fx", "rune-light", "rune-ref", "taffy", "wgpu-core"]
private let units = ["lib", "build-script", "test", "bench", "example", "doc"]

public func initialTableExampleState(count: Int = 100_000) -> TableExampleState {
    var x: UInt64 = 0x2545_f491_4f6c_dd1d
    func next() -> UInt64 {
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        return x
    }
    var rows: [Artifact] = []
    rows.reserveCapacity(count)
    for i in 0..<count {
        let r = next()
        rows.append(
            Artifact(
                id: "a\(i)",
                name: "\(crates[Int(r % 8)]) \(units[Int(UInt(truncatingIfNeeded: r >> 3) % 6)]) #\(i)",
                target: targets[Int(UInt(truncatingIfNeeded: r >> 7) % 5)],
                size: (r >> 11) % 48_000_000 + 4_096,
                ms: UInt32((r >> 37) % 90_000),
                cached: (r >> 59) % 3 != 0
            )
        )
    }
    var table = TableState(multi: true)
    table.setSort("name", .ascending)
    var state = TableExampleState(rows: rows, table: table)
    sortArtifacts(&state, col: "name", dir: .ascending)
    if state.rows.count > 2 {
        state.table.select(state.rows[2].id)
    }
    return state
}

private func formatSize(_ b: UInt64) -> String {
    if b >= (1 << 20) {
        return String(format: "%.1f MB", Double(b) / Double(1 << 20))
    }
    return String(format: "%.0f KB", Double(b) / 1024.0)
}

private func thousands(_ n: Int) -> String {
    let digits = String(n)
    var out = ""
    for (i, ch) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 {
            out.append(",")
        }
        out.append(ch)
    }
    return out
}

public func sortArtifacts(_ s: inout TableExampleState, col: String, dir: SortDir) {
    s.rows.sort { a, b in
        let cmp: ComparisonResult
        switch col {
        case "name":
            cmp = FileTreeBuilder.naturalCompare(a.name, b.name)
        case "target":
            cmp = a.target.compare(b.target)
        case "size":
            cmp = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
        case "time":
            cmp = a.ms == b.ms ? .orderedSame : (a.ms < b.ms ? .orderedAscending : .orderedDescending)
        default:
            cmp = a.cached == b.cached ? .orderedSame : (!a.cached && b.cached ? .orderedAscending : .orderedDescending)
        }
        switch dir {
        case .ascending: return cmp == .orderedAscending
        case .descending: return cmp == .orderedDescending
        }
    }
}

public func tableExampleView(_ s: TableExampleState, _ cx: inout Cx<TableExampleState>) -> El<TableExampleState> {
    let k = Kit.neutral(dark: cx.systemDark)
    let table = TableView<TableExampleState>(\.table, len: { $0.rows.count }, rowID: { $0.rows[$1].id })
        .name("Build artifacts")
        .column(TableCol("name", "Artifact").flex(2.0).min(160.0).sortable())
        .column(TableCol("target", "Target").flex(1.0).min(110.0).max(260.0).sortable())
        .column(TableCol("size", "Size").width(90.0).min(70.0).max(160.0).align(.end).sortable())
        .column(TableCol("time", "Time").width(80.0).min(64.0).max(140.0).align(.end).sortable())
        .column(TableCol("cache", "Cache").width(84.0).resizable(false).sortable())
        .cell { state, i, colId in
            let a = state.rows[i]
            switch colId {
            case "name":
                return .text(a.name)
            case "target":
                return .text(a.target).muted()
            case "size":
                return .text(formatSize(a.size)).mono()
            case "time":
                return .text(String(format: "%.1fs", Double(a.ms) / 1000.0)).mono()
            default:
                let (dot, label) = a.cached ? (k.c.success.icon, "Hit") : (k.c.iconFaint, "Miss")
                return .el(
                    row()
                        .gap(6.0)
                        .itemsCenter()
                        .child(el().size(6.0, 6.0).rounded(3.0).bg(dot))
                        .child(text(label).font(k.ty.textSmall).color(k.c.textMuted))
                )
            }
        }
        .onSort { state, col, dir, _ in
            sortArtifacts(&state, col: col, dir: dir)
        }
        .zebra(true)
        .build(s, cx: cx, kit: k)
        .grow(1.0)
        .minH(0.0)

    let count = s.table.selectedCount
    let status: El<TableExampleState> = text("\(thousands(s.rows.count)) artifacts · \(count) selected")
        .font(k.ty.textSmall)
        .color(k.c.textMuted)

    return col()
        .sizeFull()
        .bg(k.c.page)
        .p(12.0)
        .gap(8.0)
        .child(
            col()
                .key("frame")
                .wFull()
                .grow(1.0)
                .minH(0.0)
                .rounded(k.radius.md)
                .bg(k.c.bgBase)
                .clipRounded(k.radius.md)
                .child(table)
        )
        .child(row().key("status").wFull().child(status))
}

@main
public enum RuneKitTableApp {
    public static func makeSpec() -> AppSpec<TableExampleState> {
        AppSpec(
            title: "Table",
            size: Vec2(760, 480),
            state: initialTableExampleState(),
            view: tableExampleView
        )
    }

    public static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
