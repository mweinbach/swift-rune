import Foundation
import Rune

/// Side-panel layout mode (`crates/rune-knobs/src/tree.rs`).
public enum KnobLayoutMode: Int, Sendable, Equatable {
    case tree = 0
    case onScreen = 1
    case tabs = 2
}

/// A row in the side panel that the keyboard can focus.
public enum KnobTreeNode: Sendable, Equatable, Hashable {
    case page(String)
    case group(Int)
    case knob(groupIndex: Int, knobIndex: Int)
}

/// Section header style in a `KnobTreePlan`.
public enum KnobTreeHead: Sendable, Equatable {
    case page(String)
    case caption(String)
    case bare
}

/// A planned group within a section.
public struct KnobTreeSub: Sendable, Equatable {
    public var groupIndex: Int
    public var open: Bool
    public var seen: Bool
    public var knobs: [Int]
    public var full: Bool

    public init(groupIndex: Int, open: Bool, seen: Bool, knobs: [Int], full: Bool) {
        self.groupIndex = groupIndex
        self.open = open
        self.seen = seen
        self.knobs = knobs
        self.full = full
    }
}

/// A section in the side panel plan.
public struct KnobTreeSection: Sendable, Equatable {
    public var head: KnobTreeHead
    public var open: Bool
    public var seen: Bool
    public var subs: [KnobTreeSub]

    public init(head: KnobTreeHead, open: Bool, seen: Bool, subs: [KnobTreeSub]) {
        self.head = head
        self.open = open
        self.seen = seen
        self.subs = subs
    }
}

/// Complete planned layout for the side panel.
public struct KnobTreePlan: Sendable, Equatable {
    public var sections: [KnobTreeSection] = []
    public var tabs: [(String, Bool)] = []
    public var tab: String? = nil
    public var seen: Set<Int> = []

    public init(
        sections: [KnobTreeSection] = [],
        tabs: [(String, Bool)] = [],
        tab: String? = nil,
        seen: Set<Int> = []
    ) {
        self.sections = sections
        self.tabs = tabs
        self.tab = tab
        self.seen = seen
    }

    public static func == (lhs: KnobTreePlan, rhs: KnobTreePlan) -> Bool {
        lhs.sections == rhs.sections &&
        lhs.tab == rhs.tab &&
        lhs.seen == rhs.seen &&
        lhs.tabs.count == rhs.tabs.count &&
        zip(lhs.tabs, rhs.tabs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Tree planning, search filtering, and keyboard navigation (`crates/rune-knobs/src/tree.rs`).
public enum KnobTree {
    public static let seenCaption = "On screen"
    public static let restCaption = "Not on screen"

    public static func layout(for knobs: Knobs) -> KnobLayoutMode {
        let idx = Int(knobs.get(RuneKnobsDefaults.layout).rounded())
        return KnobLayoutMode(rawValue: idx) ?? .tree
    }

    public static func pages(in groups: [KnobGroup]) -> [String] {
        var out: [String] = []
        for g in groups {
            if !out.contains(g.page) {
                out.append(g.page)
            }
        }
        return out
    }

    /// Returns `true` if knob `index` in `group` matches all whitespace-separated `words`.
    public static func matches(group: KnobGroup, index: Int, words: [String]) -> Bool {
        guard index >= 0 && index < group.knobs.count else { return false }
        let d = group.knobs[index]
        let hay = "\(group.under) \(group.name) \(d.title) \(d.name) \(d.describe)".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    /// Builds a `KnobTreePlan` for `groups` given `knobs.query`, `layout`, and `seen` group indices.
    public static func plan(knobs: Knobs, groups: [KnobGroup], seen: Set<Int> = []) -> KnobTreePlan {
        let words = knobs.query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }

        func makeSub(_ g: Int, full: Bool, lead: Bool) -> KnobTreeSub {
            let isSeen = seen.contains(g)
            let isOpen = !knobs.isFolded(groups[g].name, byDefault: !(isSeen && lead))
            return KnobTreeSub(
                groupIndex: g,
                open: isOpen,
                seen: isSeen,
                knobs: Array(0..<groups[g].knobs.count),
                full: full
            )
        }

        var plan = KnobTreePlan()
        plan.seen = seen

        if !words.isEmpty {
            var subs: [KnobTreeSub] = []
            for g in 0..<groups.count {
                let matchingKnobs = (0..<groups[g].knobs.count).filter { matches(group: groups[g], index: $0, words: words) }
                if !matchingKnobs.isEmpty {
                    var sub = makeSub(g, full: true, lead: true)
                    sub.open = true
                    sub.knobs = matchingKnobs
                    subs.append(sub)
                }
            }
            plan.sections.append(KnobTreeSection(head: .bare, open: true, seen: false, subs: subs))
            return plan
        }

        func groupsOf(page: String) -> [Int] {
            (0..<groups.count).filter { groups[$0].page == page }
        }

        switch layout(for: knobs) {
        case .tree:
            for p in pages(in: groups) {
                let gs = groupsOf(page: p)
                let lit = gs.contains { seen.contains($0) }
                if gs.count == 1 && groups[gs[0]].under.isEmpty {
                    plan.sections.append(KnobTreeSection(
                        head: .bare,
                        open: true,
                        seen: lit,
                        subs: [makeSub(gs[0], full: false, lead: false)]
                    ))
                } else {
                    let holds = gs.contains { g in
                        knobs.group == groups[g].name && knobs.unfolded.contains(groups[g].name)
                    }
                    let isOpen = !knobs.isFolded(p, byDefault: !holds)
                    plan.sections.append(KnobTreeSection(
                        head: .page(p),
                        open: isOpen,
                        seen: lit,
                        subs: gs.map { makeSub($0, full: false, lead: false) }
                    ))
                }
            }

        case .onScreen:
            let on = (0..<groups.count).filter { seen.contains($0) }
            let off = (0..<groups.count).filter { !seen.contains($0) }
            if !on.isEmpty {
                plan.sections.append(KnobTreeSection(
                    head: .caption(seenCaption),
                    open: true,
                    seen: true,
                    subs: on.map { makeSub($0, full: true, lead: true) }
                ))
            }
            if !off.isEmpty {
                plan.sections.append(KnobTreeSection(
                    head: .caption(restCaption),
                    open: true,
                    seen: false,
                    subs: off.map { makeSub($0, full: true, lead: true) }
                ))
            }

        case .tabs:
            let allTabs = pages(in: groups).map { p in
                (p, groupsOf(page: p).contains { seen.contains($0) })
            }
            plan.tabs = allTabs
            let picked = knobs.tab.flatMap { t in allTabs.first(where: { $0.0 == t }) }
            let activeTab = (picked ?? allTabs.first(where: { $0.1 }) ?? allTabs.first)?.0
            plan.tab = activeTab
            if let t = activeTab {
                plan.sections.append(KnobTreeSection(
                    head: .bare,
                    open: true,
                    seen: true,
                    subs: groupsOf(page: t).map { makeSub($0, full: false, lead: true) }
                ))
            }
        }

        return plan
    }

    /// Returns the flattened list of navigable rows in `plan`.
    public static func rows(in plan: KnobTreePlan) -> [KnobTreeNode] {
        var out: [KnobTreeNode] = []
        for sec in plan.sections {
            if case .page(let p) = sec.head {
                out.append(.page(p))
            }
            guard sec.open else { continue }
            for sub in sec.subs {
                out.append(.group(sub.groupIndex))
                guard sub.open else { continue }
                for k in sub.knobs {
                    out.append(.knob(groupIndex: sub.groupIndex, knobIndex: k))
                }
            }
        }
        return out
    }

    /// Handles keyboard navigation inside the side panel tree (`↑/↓`, `←/→`, `/`, `Esc`, `[`, `]`).
    @discardableResult
    public static func handleKey(
        _ knobs: inout Knobs,
        groups: [KnobGroup],
        seen: Set<Int> = [],
        event: KeyEvent
    ) -> Bool {
        if knobs.filtering {
            if event.key == .escape || event.key == .enter {
                knobs.stopFilter()
                return true
            }
            return false
        }
        if event.mods.cmd || event.mods.alt || event.mods.ctrl {
            return false
        }

        if event.key == .text("/") {
            knobs.startFilter()
            return true
        }

        if event.key == .escape {
            if !knobs.query.isEmpty {
                knobs.setQuery("")
                return true
            }
            knobs.close()
            return true
        }

        let currentPlan = plan(knobs: knobs, groups: groups, seen: seen)
        let rowList = rows(in: currentPlan)
        guard !rowList.isEmpty else { return false }

        let currentIdx = knobs.treeAt.flatMap { rowList.firstIndex(of: $0) } ?? 0

        switch event.key {
        case .arrowUp, .arrowDown:
            let delta = event.key == .arrowDown ? 1 : -1
            let nextIdx = ((currentIdx + delta) % rowList.count + rowList.count) % rowList.count
            knobs.treeAt = rowList[nextIdx]
            knobs.kbd = true
            return true

        case .arrowLeft, .arrowRight:
            let right = event.key == .arrowRight
            let node = rowList[currentIdx]
            switch node {
            case .page(let p):
                knobs.setFolded(p, !right)
            case .group(let gi):
                knobs.setFolded(groups[gi].name, !right)
            case .knob(let gi, let ki):
                let k = groups[gi].knobs[ki]
                knobs.step(k, up: right, big: event.mods.shift)
            }
            knobs.kbd = true
            return true

        case .text(let t) where t.count == 1 && ("1"..."9").contains(t):
            if let num = Int(t) {
                let optIdx = num - 1
                let node = rowList[currentIdx]
                if case .knob(let gi, let ki) = node {
                    let k = groups[gi].knobs[ki]
                    if optIdx < k.labels.count {
                        knobs.checkpoint()
                        knobs.set(k, Float(optIdx))
                    }
                }
                knobs.kbd = true
                return true
            }
            return false

        default:
            return false
        }
    }
}
