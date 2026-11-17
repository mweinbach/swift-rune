import Foundation

/// The visible menu bar at a single revision. Actions stay with the app that owns them.
struct DesktopMenuSnapshot: Sendable {
    let revision: UInt64
    let sections: [DesktopMenuSection]

    init<State>(revision: UInt64, items: [NativeMenuItem<State>], applicationTitle: String) {
        self.revision = revision
        let appTitle = applicationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Application" : applicationTitle
        var titles = [appTitle]
        var groups: [String: [NativeMenuItem<State>]] = [:]
        for item in items {
            let title: String
            switch item.location {
            case .app: title = appTitle
            case .named(let name): title = name
            case .dock: continue
            }
            if title != appTitle && groups[title] == nil {
                titles.insert(title, at: StandardMenuItem.topIndex(name: title, tops: titles))
            }
            groups[title, default: []].append(item)
        }
        sections = titles.compactMap { title in
            guard let items = groups[title] else { return nil }
            return DesktopMenuSection(title: title, items: items)
        }
    }

    func matching(_ event: KeyEvent, on platform: KeyPlatform = .current) -> DesktopMenuEntry? {
        for section in sections {
            if let item = section.items.first(where: {
                $0.enabled && !$0.isSeparator && $0.accelerator?.matches(event, on: platform) == true
            }) {
                return item
            }
        }
        return nil
    }
}

struct DesktopMenuSection: Sendable {
    let title: String
    let items: [DesktopMenuEntry]

    fileprivate init<State>(title: String, items: [NativeMenuItem<State>]) {
        self.title = title
        var order: [Int] = []
        var anchors: [String: Int] = [:]
        for (offset, item) in items.enumerated() {
            if let after = item.afterId, let anchor = anchors[after], let index = order.firstIndex(of: anchor) {
                order.insert(offset, at: index + 1)
                // Subsequent siblings follow this item, including separators without a unique ID.
                anchors[after] = offset
            } else {
                order.append(offset)
            }
            if !item.isSeparator { anchors[item.id] = offset }
        }
        self.items = order.map { DesktopMenuEntry(items[$0]) }
    }
}

struct DesktopMenuEntry: Sendable {
    let id: String
    let title: String
    let isSeparator: Bool
    let checked: Bool
    let enabled: Bool
    let keysFirst: Bool
    let accelerator: Chord?

    fileprivate init<State>(_ item: NativeMenuItem<State>) {
        id = item.id
        title = item.title
        isSeparator = item.isSeparator
        checked = item.checked
        enabled = item.enabled
        keysFirst = item.keysFirst
        accelerator = item.isSeparator ? nil : item.keyEquivalent.flatMap(Chord.init(parsing:))
    }
}
