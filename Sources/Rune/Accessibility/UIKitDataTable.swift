#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Row and column coordinates of the currently exposed descendants of one table.
@MainActor
internal final class UIKitAccessibilityTable {
    private struct MountedRow {
        let position: Int?
        let setSize: Int?
        var cells: [RuneUIAccessibilityElement] = []
    }

    let rowCount: Int
    let columnCount: Int
    fileprivate var cellsByRow: [Int: [RuneUIAccessibilityElement]] = [:]
    fileprivate var rowHeaders: [Int: [any UIAccessibilityContainerDataTableCell]] = [:]
    fileprivate var columnHeaders: [Int: [any UIAccessibilityContainerDataTableCell]] = [:]

    /// RuneKit's virtual Table has unnumbered header rows followed by a window into one numbered set.
    private static func virtualRows(_ rows: [MountedRow]) -> (count: Int, indices: [Int])? {
        guard let prefix = rows.firstIndex(where: { $0.position != nil || $0.setSize != nil }),
              let size = rows[prefix].setSize, size > 0, size <= Int.max - prefix,
              rows[..<prefix].allSatisfy({ row in
                  !row.cells.isEmpty && row.cells.allSatisfy { $0.semanticRole == .columnHeader }
              }) else { return nil }

        var indices = Array(0..<prefix)
        var previous = -1
        for row in rows[prefix...] {
            guard let position = row.position, row.setSize == size,
                  position > previous, position < size else { return nil }
            indices.append(prefix + position)
            previous = position
        }
        return (prefix + size, indices)
    }

    init(element: RuneUIAccessibilityElement) {
        var rows: [MountedRow] = []
        var nestedRows = false
        func collect(_ parent: RuneUIAccessibilityElement, row: Int?) {
            guard let children = parent.accessibilityElements else { return }
            for case let child as RuneUIAccessibilityElement in children {
                switch child.semanticRole {
                case .table, .grid, .treeGrid:
                    continue
                case .row:
                    if row != nil { nestedRows = true }
                    let index = rows.count
                    rows.append(MountedRow(position: child.setPosition, setSize: child.setSize))
                    collect(child, row: index)
                case .cell, .gridCell, .rowHeader, .columnHeader:
                    if let row { rows[row].cells.append(child) }
                default:
                    collect(child, row: row)
                }
            }
        }
        collect(element, row: nil)
        let virtual = nestedRows ? nil : Self.virtualRows(rows)
        rowCount = virtual?.count ?? rows.count
        columnCount = rows.lazy.map(\.cells.count).max() ?? 0
        cellsByRow.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            let logical = virtual?.indices[index] ?? index
            cellsByRow[logical] = row.cells
            for (column, cell) in row.cells.enumerated() {
                cell.tableRow = logical
                cell.tableColumn = column
                if cell.semanticRole == .rowHeader {
                    rowHeaders[logical, default: []].append(cell)
                } else if cell.semanticRole == .columnHeader {
                    columnHeaders[column, default: []].append(cell)
                }
            }
        }
    }
}

extension RuneUIAccessibilityElement: UIAccessibilityContainerDataTable, UIAccessibilityContainerDataTableCell {
    public func accessibilityRowCount() -> Int { tableData?.rowCount ?? 0 }
    public func accessibilityColumnCount() -> Int { tableData?.columnCount ?? 0 }

    public func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
        guard let cells = tableData?.cellsByRow[row], cells.indices.contains(column) else {
            return nil
        }
        return cells[column]
    }

    public func accessibilityRowRange() -> NSRange {
        guard let row = tableRow else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: row, length: 1)
    }

    public func accessibilityColumnRange() -> NSRange {
        guard let column = tableColumn else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: column, length: 1)
    }

    public func accessibilityHeaderElements(forRow row: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        tableData?.rowHeaders[row]
    }

    public func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        tableData?.columnHeaders[column]
    }
}
#endif
