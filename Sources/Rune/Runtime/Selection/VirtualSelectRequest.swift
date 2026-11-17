import Foundation

/// A `Tx.selectText` / `Tx.selectAllText` request (`el::SelectRequest`, without `Clear`, which
/// `applySelectionTx` carries out itself).
internal enum VirtualSelectRequest: Equatable {
    case range(String, Range<Int>)
    case all(String)

    var selector: String {
        switch self {
        case .range(let k, _), .all(let k): return k
        }
    }
}

internal extension Runtime {
    /// The first mounted node `selector` names, its path or its keyed path, that's not leaving
    /// and is allowed (`select_request`'s `named`, `Node::named`).
    func namedSelectionNode(_ selector: String) -> Int? {
        flatNodes.indices.first { i in
            let n = flatNodes[i]
            return (n.path == selector || FlightSelector.selects(selector, path: n.path, key: n.key))
                && !selectionSubtreeExiting(i) && selectionAllowed(i)
        }
    }

    /// `Tx.selectAllText(key)` (`select_request` `SelectRequest::All`): the named element's span
    /// across a virtual list under it, rows built on demand at either end
    /// (`virtual_span_under`), else all of it mounted; with nothing mounted by that name, and
    /// `unmounted`, the element in a row that isn't (`select_unmounted_request`).
    func applySelectAllRequest(_ key: String, snaps: () -> [SelectableNodeSnapshot], unmounted: Bool) -> Bool {
        let named = namedSelectionNode(key)
        if let i = named, let span = virtualSpanUnder(root: i) {
            selectSpanEnds(first: span.first, last: span.last)
            return true
        }
        let s = snaps()
        if !s.isEmpty, selectionState.coordinator.selectAllText(key: key, in: s) != nil {
            sealBetween()
            return true
        }
        if let i = named, !s.isEmpty, selectionState.coordinator.selectAllText(key: flatNodes[i].path, in: s) != nil {
            sealBetween()
            return true
        }
        return unmounted && named == nil && selectUnmountedRequest(.all(key))
    }

    /// `Tx.selectText(key, range)` (`select_request` `SelectRequest::Range`): the named mounted
    /// text, else, with `unmounted`, the named text in a row that isn't mounted
    /// (`select_unmounted_request`).
    func applySelectTextRequest(_ key: String, range: Range<Int>, snaps: () -> [SelectableNodeSnapshot], unmounted: Bool) -> Bool {
        let s = snaps()
        if !s.isEmpty, selectionState.coordinator.selectText(key: key, range: range, in: s) != nil {
            sealBetween()
            return true
        }
        let named = namedSelectionNode(key).flatMap { selectableLive($0) ? $0 : nil }
        if let i = named, !s.isEmpty, selectionState.coordinator.selectText(key: flatNodes[i].path, range: range, in: s) != nil {
            sealBetween()
            return true
        }
        return unmounted && named == nil && selectUnmountedRequest(.range(key, range))
    }

    /// Carries out a `Tx.selectText` / `Tx.selectAllText` whose selector names an element in a
    /// virtual row that isn't mounted: builds the rows the selector names (or, naming none of
    /// them, up to `VirtualCopyLimits.maxRows` unmounted rows) until one holds the element, and
    /// selects there without scrolling (`Runtime::select_unmounted_request`).
    func selectUnmountedRequest(_ request: VirtualSelectRequest) -> Bool {
        let selector = request.selector
        let lists = virtualSelectionSources.keys
            .compactMap { lp in virtualListAllowed(lp).map { (lp, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let selectorSegments = selector.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for listPath in lists {
            guard let src = virtualSelectionSources[listPath] else { continue }
            let range = src.mounted
            var candidates = src.keys.indices.filter { r in
                guard !range.contains(r) else { return false }
                let rk = src.keys[r]
                return selector == rk || selector.hasPrefix(rk + "/") || selectorSegments.contains(rk)
            }
            if candidates.isEmpty {
                candidates = Array(src.keys.indices.lazy.filter { !range.contains($0) }.prefix(VirtualCopyLimits.maxRows))
            }
            for r in candidates {
                let texts = offscreenRowSelectables(listPath: listPath, src: src, row: r)
                func names(_ t: OffscreenSelectable) -> Bool {
                    t.path == selector || FlightSelector.selects(selector, path: t.path, key: t.key)
                }
                switch request {
                case .range(_, let byteRange):
                    guard let t = texts.first(where: names) else { continue }
                    let a = SelectionMath.floorCharBoundary(in: t.text, offset: byteRange.lowerBound)
                    let b = SelectionMath.floorCharBoundary(in: t.text, offset: max(byteRange.upperBound, byteRange.lowerBound))
                    guard let end = resolveSelectionEnd(path: t.path, end: nil) else { return false }
                    selectionState.isDraggingSelection = false
                    selectionState.coordinator.phase.place(ActiveSelection(
                        path: t.path,
                        content: t.text,
                        anchor: a,
                        focus: b,
                        origin: (a, b),
                        anchorEnd: virtualEnd(forPath: end.path, offset: a)
                    ))
                    sealBetween()
                    return true
                case .all:
                    let rowKey = src.keys[r]
                    let rowPath = "\(listPath)/@\(rowKey)"
                    let rowMatches = rowPath == selector || FlightSelector.selects(selector, path: rowPath, key: rowKey)
                    let matching = rowMatches ? texts : texts.filter(names)
                    guard let firstT = matching.first else { continue }
                    let lastT = firstT.group.map { g in matching.last(where: { $0.group == g }) ?? firstT } ?? firstT
                    guard let e0 = resolveSelectionEnd(path: firstT.path, end: nil),
                          let e1 = resolveSelectionEnd(path: lastT.path, end: nil) else { return false }
                    selectSpanEnds(first: e0, last: e1)
                    return true
                }
            }
        }
        return false
    }
}
