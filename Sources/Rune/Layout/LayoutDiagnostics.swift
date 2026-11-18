import Foundation
import RuneTaffy

/// Debug-only layout warnings for mistakes that lay out without error but look broken.
/// Port of `crates/rune/src/runtime/commit/layout_diagnostics.rs`.
public enum LayoutDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var warnedSites: Set<String> = []

    /// Emits each layout diagnostic once per element path in debug builds.
    static func checkCollapsedScrolls<State>(
        nodes: [Runtime<State>.FlatNode],
        warnHandler: ((String) -> Void)? = nil
    ) {
        func warnOnce(_ key: String, _ message: String) {
            let inserted: Bool = lock.withLock {
                warnedSites.insert(key).inserted
            }
            guard inserted else { return }
            if let warnHandler {
                warnHandler(message)
            } else {
                #if DEBUG
                RuneStandardIO.error(message + "\n")
                #endif
            }
        }

        for i in nodes.indices {
            let n = nodes[i]
            let style = n.el.layout
            if style.wholeRows && (!style.isWholeRowsColumn || style.forcesHorizontalFlexRow(childCount: n.el.children.count)) {
                warnOnce("whole-rows-dir:\(n.path)", "rune: .wholeRows() on \(n.path) requires a non-wrapping flex column. (debug builds only)")
            }
            guard !style.scrollAxes.isEmpty else { continue }
            let site = n.path
            let directChildren = nodes.indices.filter { nodes[$0].parentIndex == i }

            if n.el.growthSpec != nil {
                let msg = "rune: scroll viewport \(n.path) (.scroll at \(site)) also sets .growth(..); "
                    + "put .growth(..) on a child column inside .scroll(..) so the viewport box "
                    + "does not take the stack's presented height. (debug builds only)"
                warnOnce("growth:\(site)", msg)
            }

            if let firstGrowthRelIdx = directChildren.firstIndex(where: { nodes[$0].el.growthSpec != nil }),
               firstGrowthRelIdx + 1 < directChildren.count {
                let gNode = nodes[directChildren[firstGrowthRelIdx]]
                let msg = "rune: growth stack \(gNode.path) inside scroll viewport \(n.path) (.scroll at \(site)) "
                    + "has sibling elements after it; a growth stack must be the last (or only) "
                    + "child of its scroll viewport so nothing below it overlaps its growing rows. (debug builds only)"
                warnOnce("growth-sibling:\(site)", msg)
            }

            guard n.el.layout.scrollAxes.contains(.vertical),
                  n.targetRect.height < 0.5 else {
                continue
            }

            var content: Float = 0.0
            for j in directChildren {
                let childRect = nodes[j].targetRect
                let relBottom = (childRect.top - n.targetRect.top) + childRect.height
                content = max(content, relBottom)
            }
            guard content >= 0.5 else { continue }

            var up: Int? = i
            var collapsed = false
            while let cur = up {
                let curNode = nodes[cur]
                let isGrown = curNode.el.layout.flexGrow > 0.0 && curNode.el.layout.flexBasis == .points(0)
                if isGrown && curNode.targetRect.height < 0.5 {
                    collapsed = true
                    break
                }
                up = curNode.parentIndex
            }
            guard collapsed else { continue }

            let msg = "rune: scroll viewport \(n.path) (.scroll at \(site)) is 0 pt tall inside a .grow() container "
                + "while its content is \(content) pt. .grow() sets flex-basis 0, so it only fills space a "
                + "bounded parent leaves: bound an ancestor's height (.h(..), .h_full()) or set .min_h(..), "
                + "and put .min_h(0.0) on nested flex columns. (debug builds only)"
            warnOnce(site, msg)
        }
    }

    /// Returns whether any recorded warning site contains `needle`.
    public static func hasWarned(matching needle: String) -> Bool {
        lock.withLock {
            warnedSites.contains { $0.contains(needle) }
        }
    }

    /// Resets deduplicated warning sites (for test isolation).
    public static func resetWarnedSitesForTesting() {
        lock.withLock {
            warnedSites.removeAll()
        }
    }
}
