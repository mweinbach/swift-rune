import Rune

/// A detached render has no measured rows. Derive the same window as a uniform
/// VirtualListState, without allocating a key or a prefix-sum entry for every row.
internal func detachedListWindow(
    count: Int, estimate: Float, gap: Float, scrollY: Float, viewportHeight: Float
) -> VirtualWindow {
    guard count > 0 else { return VirtualWindow() }
    let height = max(1, Double(estimate))
    let stride = height + max(0, Double(gap))
    func rowTop(_ i: Int) -> Double { i == 0 ? 0 : Double(i) * stride }

    func firstIndex(where reached: (Double) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if reached(rowTop(mid)) { upper = mid } else { lower = mid + 1 }
        }
        return lower
    }
    func firstRow(at offset: Double) -> Int {
        min(count - 1, firstIndex { $0 + height > offset })
    }
    func pastLastRow(at offset: Double) -> Int {
        firstIndex { $0 >= offset }
    }

    let total = rowTop(count - 1) + height
    let top = max(0, Double(scrollY))
    let bottom = top + max(0, Double(viewportHeight))
    let visibleStart = firstRow(at: top)
    let visibleEnd = max(visibleStart, pastLastRow(at: bottom))
    // Match VirtualListState's default overscan of 200 pixels plus two rows per edge.
    let start = max(0, firstRow(at: max(0, top - 200)) - 2)
    let endIndex = pastLastRow(at: min(total, bottom + 200))
    let end = max(start, endIndex + min(2, count - endIndex))
    let mountedBottom = end > 0 ? rowTop(end - 1) + height : 0
    return VirtualWindow(
        mountedRange: start..<end, visibleRange: visibleStart..<visibleEnd,
        beforeHeight: Float(rowTop(start)), afterHeight: Float(max(0, total - mountedBottom)),
        totalHeight: Float(total)
    )
}
