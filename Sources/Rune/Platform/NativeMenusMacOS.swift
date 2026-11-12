import Foundation

#if os(macOS)
import AppKit
import ObjectiveC.runtime

/// Default macOS menu bar & standard Edit/Window menu installation (`native_menu/default_macos.rs`).
@MainActor
public enum RuneDefaultMacMenus {
    private static let standardTag: Int = 0x5255_4e45
    private static let appItemTag: Int = 0x5255_4e46
    private static let namedPrefix = "rune.menu."
    private static var pendingAppMenu: NSMenu?

    /// Preserves any existing menu bar, or installs the default macOS app menu ending in ⌘Q.
    @discardableResult
    public static func ensure(_ app: NSApplication = .shared) -> NSMenu {
        if let root = app.mainMenu {
            return root
        }
        let root = emptyRoot(app)
        if let appMenu = pendingAppMenu {
            pendingAppMenu = nil
            addAppItems(app: app, to: appMenu)
        }
        return root
    }

    /// Populates a deferred app menu when an accessory app promotes to regular.
    public static func promote(_ app: NSApplication = .shared) {
        _ = ensure(app)
        if let appMenu = pendingAppMenu {
            pendingAppMenu = nil
            addAppItems(app: app, to: appMenu)
        }
    }

    /// Creates a menu bar whose first item holds an empty app menu stored in `pendingAppMenu`.
    public static func emptyRoot(_ app: NSApplication = .shared) -> NSMenu {
        let root = NSMenu()
        let top = NSMenuItem()
        let appMenu = NSMenu()
        top.submenu = appMenu
        root.addItem(top)
        app.mainMenu = root
        pendingAppMenu = appMenu
        return root
    }

    /// Installs the standard Edit and Window menus into `app.mainMenu`, preserving existing items.
    public static func addStandardMenus(_ app: NSApplication = .shared) {
        let root = app.mainMenu ?? emptyRoot(app)
        for standard in StandardMenuItem.items {
            let menu = findOrCreateTop(root: root, name: standard.menu).1
            let action = Selector(standard.action)
            let alreadyExists = menu.items.contains { $0.action == action }
            if alreadyExists { continue }
            if standard.separatorBefore && menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            let title = RuneLabels.shared.label(for: standard.label)
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: String(standard.key))
            var flags: NSEvent.ModifierFlags = [.command]
            if standard.shift { flags.insert(.shift) }
            entry.keyEquivalentModifierMask = flags
            entry.tag = standardTag
            menu.addItem(entry)
        }
        syncStandard(app)
    }

    /// Recursively sets layout direction on `menu` and its submenus (#836 RTL).
    public static func setLayoutDirection(_ menu: NSMenu) {
        let dir: NSUserInterfaceLayoutDirection = RuneLabels.shared.isRTL ? .rightToLeft : .leftToRight
        menu.userInterfaceLayoutDirection = dir
        for entry in menu.items {
            if let sub = entry.submenu {
                setLayoutDirection(sub)
            }
        }
    }

    /// Retitles standard items, app menu items, and named menus Rune created with `RuneLabels.shared`.
    public static func relabel(_ app: NSApplication = .shared) {
        guard let root = app.mainMenu else { return }
        for (index, top) in root.items.enumerated() {
            guard let sub = top.submenu else { continue }
            if index == 0 {
                relabelAppItems(in: sub)
            }
            if let name = identifierName(top) {
                let title = RuneLabels.shared.label(for: .menu(name))
                top.title = title
                sub.title = title
            }
            for entry in sub.items where entry.tag == standardTag {
                if let action = entry.action, let standard = StandardMenuItem.byAction(NSStringFromSelector(action)) {
                    entry.title = RuneLabels.shared.label(for: standard.label)
                }
            }
        }
    }

    /// Executes `body` while standard equivalents are temporarily cleared so AppKit keeps custom claims.
    public static func adding(_ app: NSApplication = .shared, _ body: () -> Void) {
        setStandardKeys(app) { _ in false }
        body()
        syncStandard(app)
    }

    /// Restores key equivalents on standard items not claimed by custom items anywhere in the bar.
    public static func syncStandard(_ app: NSApplication = .shared) {
        var claimed = Set<StandardEquivalent>()
        if let root = app.mainMenu {
            collectClaims(in: root, into: &claimed)
        }
        setStandardKeys(app) { !claimed.contains($0) }
    }

    public static func topName(_ top: NSMenuItem) -> String {
        identifierName(top) ?? top.title
    }

    public static func isWinitDefault(_ app: NSApplication = .shared) -> Bool {
        guard let root = app.mainMenu else { return false }
        let actions: [String?] = root.items.first?.submenu?.items.map { item in
            item.action.map { NSStringFromSelector($0) }
        } ?? []
        return StandardMenuItem.isWinitDefault(topCount: root.numberOfItems, appMenuActions: actions)
    }

    @discardableResult
    public static func addTop(root: NSMenu, name: String) -> (NSMenuItem, NSMenu) {
        let tops = root.items.map { topName($0) }
        let title = RuneLabels.shared.label(for: .menu(name))
        let menu = NSMenu(title: title)
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.identifier = NSUserInterfaceItemIdentifier("\(namedPrefix)\(name)")
        entry.submenu = menu
        let index = StandardMenuItem.topIndex(name: name, tops: tops)
        root.insertItem(entry, at: index)
        return (entry, menu)
    }

    public static func removeTopIfEmpty(root: NSMenu, top: NSMenuItem) {
        let count = top.submenu?.numberOfItems ?? 0
        if count == 0 && root.index(of: top) >= 0 {
            root.removeItem(top)
        }
    }

    @discardableResult
    public static func findOrCreateTop(root: NSMenu, name: String) -> (NSMenuItem?, NSMenu) {
        if let existing = root.items.first(where: { topName($0) == name }), let sub = existing.submenu {
            return (nil, sub)
        }
        let (entry, sub) = addTop(root: root, name: name)
        return (entry, sub)
    }

    private static func identifierName(_ top: NSMenuItem) -> String? {
        guard let raw = top.identifier?.rawValue, raw.hasPrefix(namedPrefix) else { return nil }
        return String(raw.dropFirst(namedPrefix.count))
    }

    private static func addAppItems(app: NSApplication, to menu: NSMenu) {
        let servicesMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu

        let aboutItem = NSMenuItem(title: "", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let sep1 = NSMenuItem.separator()
        let hideItem = NSMenuItem(title: "", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.option, .command]
        let showAllItem = NSMenuItem(title: "", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        let sep2 = NSMenuItem.separator()
        let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for entry in [aboutItem, sep1, servicesItem, hideItem, hideOthersItem, showAllItem, sep2, quitItem] {
            entry.tag = appItemTag
            menu.addItem(entry)
        }
        app.servicesMenu = servicesMenu
        relabelAppItems(in: menu)
    }

    private static func relabelAppItems(in menu: NSMenu) {
        let processName = ProcessInfo.processInfo.processName
        for entry in menu.items where entry.tag == appItemTag {
            let label: RuneLabel?
            if let action = entry.action {
                switch NSStringFromSelector(action) {
                case "orderFrontStandardAboutPanel:": label = .about(processName)
                case "hide:": label = .hide(processName)
                case "hideOtherApplications:": label = .hideOthers
                case "unhideAllApplications:": label = .showAll
                case "terminate:": label = .quit(processName)
                default: label = nil
                }
            } else if !entry.isSeparatorItem && entry.submenu != nil {
                label = .services
            } else {
                label = nil
            }
            if let label {
                entry.title = RuneLabels.shared.label(for: label)
            }
        }
    }

    private static func setStandardKeys(_ app: NSApplication, keep: (StandardEquivalent) -> Bool) {
        guard let root = app.mainMenu else { return }
        for top in root.items {
            guard let sub = top.submenu else { continue }
            for entry in sub.items where entry.tag == standardTag {
                guard let action = entry.action, let standard = StandardMenuItem.byAction(NSStringFromSelector(action)) else {
                    continue
                }
                entry.keyEquivalent = keep(standard.equivalent) ? String(standard.key) : ""
            }
        }
    }

    private static func collectClaims(in menu: NSMenu, into out: inout Set<StandardEquivalent>) {
        for entry in menu.items {
            if entry.tag != standardTag {
                let flags = entry.keyEquivalentModifierMask
                if let eq = StandardEquivalent(
                    key: entry.keyEquivalent,
                    cmd: flags.contains(.command),
                    shift: flags.contains(.shift),
                    alt: flags.contains(.option),
                    ctrl: flags.contains(.control)
                ) {
                    out.insert(eq)
                }
            }
            if let sub = entry.submenu {
                collectClaims(in: sub, into: &out)
            }
        }
    }
}

/// Bridges standard menu selectors (`copy:`, `performClose:`, etc.) and `keysFirst` custom items
/// into the active `Rune` view (`native_menu/standard_macos.rs`).
@MainActor
public enum RuneStandardMenuRouter {
    public typealias KeyEventDispatcher = @MainActor (KeyEvent) -> Bool
    public typealias NativeEventDispatcher = @MainActor (NSEvent) -> Bool

    private static var reenteringButton = false
    private static var activeNativeKeyDispatcher: (() -> NativeEventDispatcher?)?

    public static func setActiveKeyDispatcher(_ provider: (() -> NativeEventDispatcher?)?) {
        activeNativeKeyDispatcher = provider
    }

    /// Defers a `keysFirst` menu action when triggered by a `.keyDown` event so Rune handles it first.
    /// Returns `true` if deferred/consumed; returns `false` if no active view exists (run immediately).
    public static func deferKey(_ run: @escaping @MainActor () -> Void) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else {
            return false
        }
        guard let dispatch = activeNativeKeyDispatcher?() else {
            return false
        }
        let handled = dispatch(event)
        if !handled {
            run()
        }
        return true
    }

    /// Routes a standard menu selector (Edit / Window) to the view first, then falls back to window button.
    public static func performStandardAction(
        selector: String,
        window: NSWindow?,
        dispatchKeyEvent: KeyEventDispatcher,
        dispatchNativeEvent: NativeEventDispatcher
    ) {
        guard !reenteringButton, let standard = StandardMenuItem.byAction(selector) else { return }

        let currentSnapshot: StandardKeyDown?
        let currentEvent = NSApp.currentEvent
        if let ev = currentEvent, ev.type == .keyDown {
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            currentSnapshot = StandardKeyDown(
                chars: ev.charactersIgnoringModifiers ?? "",
                cmd: flags.contains(.command),
                shift: flags.contains(.shift),
                alt: flags.contains(.option),
                ctrl: flags.contains(.control)
            )
        } else {
            currentSnapshot = nil
        }

        let hasButton: Bool
        switch standard.role {
        case .close:
            hasButton = window?.styleMask.contains(.closable) ?? false
        case .minimize:
            hasButton = window?.styleMask.contains(.miniaturizable) ?? false
        default:
            hasButton = false
        }

        let route = standard.route(hasButton: hasButton, current: currentSnapshot)
        let handled: Bool
        if route.current, let ev = currentEvent {
            handled = dispatchNativeEvent(ev)
        } else {
            let mods = Mods(shift: standard.shift, ctrl: false, alt: false, cmd: true, logo: false)
            handled = dispatchKeyEvent(KeyEvent(key: .command(standard.key), mods: mods))
        }

        if !handled && route.thenButton, let window {
            reenteringButton = true
            defer { reenteringButton = false }
            switch standard.role {
            case .close:
                window.performClose(nil)
            case .minimize:
                window.performMiniaturize(nil)
            default:
                break
            }
        }
    }
}

/// Target object attached to custom `NSMenuItem`s built by `RuneNativeMenuHost`.
@MainActor
public final class RuneNativeMenuTarget: NSObject {
    public let itemId: String
    public let isEnabledFlag: Bool
    public let keysFirst: Bool
    private let handler: @MainActor (String) -> Void

    public init(itemId: String, enabled: Bool, keysFirst: Bool, handler: @escaping @MainActor (String) -> Void) {
        self.itemId = itemId
        self.isEnabledFlag = enabled
        self.keysFirst = keysFirst
        self.handler = handler
        super.init()
    }

    @objc public func runeMenuAction(_ sender: NSMenuItem) {
        guard isEnabledFlag else { return }
        let id = itemId
        let cb = handler
        if keysFirst && RuneStandardMenuRouter.deferKey({ cb(id) }) {
            return
        }
        cb(id)
    }

    @objc public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabledFlag
    }
}

/// Installs and replaces custom macOS menu snapshots and Dock menus (`native_menu/macos.rs`).
@MainActor
public final class RuneNativeMenuHost {
    public static let shared = RuneNativeMenuHost()

    private var entries: [(menu: NSMenu, item: NSMenuItem)] = []
    private var tops: [(root: NSMenu, top: NSMenuItem)] = []
    private var targets: [RuneNativeMenuTarget] = []
    private var dockMenu: NSMenu?
    private var jumpMenu: NSMenu?
    private var jumpTargets: [RuneNativeMenuTarget] = []
    private var dockHookedClassName: String?

    public init() {}

    public func clear() {
        for pair in entries {
            pair.item.target = nil
            pair.item.action = nil
            pair.menu.removeItem(pair.item)
        }
        entries.removeAll()
        for topPair in tops {
            RuneDefaultMacMenus.removeTopIfEmpty(root: topPair.root, top: topPair.top)
        }
        tops.removeAll()
        targets.removeAll()
        dockMenu = nil
        RuneDefaultMacMenus.syncStandard()
    }

    public func apply<State>(
        items: [NativeMenuItem<State>],
        onSelect: @escaping @MainActor (String) -> Void
    ) throws {
        try NativeMenuValidator.validate(items)
        let app = NSApplication.shared
        if items.contains(where: { $0.location == .dock }) {
            try installDockHook(app)
        }

        // Prepare items and targets before clearing the previous snapshot.
        var prepared: [(NativeMenuItem<State>, NSMenuItem, RuneNativeMenuTarget?)] = []
        prepared.reserveCapacity(items.count)
        for desc in items {
            if desc.isSeparator {
                prepared.append((desc, NSMenuItem.separator(), nil))
                continue
            }
            let target = RuneNativeMenuTarget(
                itemId: desc.id,
                enabled: desc.enabled,
                keysFirst: desc.keysFirst,
                handler: onSelect
            )
            let item = NSMenuItem(
                title: desc.title,
                action: #selector(RuneNativeMenuTarget.runeMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.isEnabled = desc.enabled
            item.state = desc.checked ? .on : .off
            if let eqRaw = desc.keyEquivalent, let eq = MenuKeyEquivalent(parsing: eqRaw) {
                item.keyEquivalent = eq.key
                item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: eq.modifierMask)
            } else if let eqRaw = desc.keyEquivalent, !eqRaw.isEmpty {
                item.keyEquivalent = eqRaw
            }
            prepared.append((desc, item, target))
        }

        clear()
        RuneDefaultMacMenus.adding(app) {
            var appIndex = 0
            var placed: [(String, NSMenuItem)] = []
            var chained: [(String, NSMenuItem)] = []

            for (desc, item, target) in prepared {
                let menu: NSMenu
                switch desc.location {
                case .dock:
                    let d = dockMenu ?? NSMenu()
                    dockMenu = d
                    menu = d
                case .app:
                    let root = RuneDefaultMacMenus.ensure(app)
                    if root.numberOfItems == 0 {
                        let (topEntry, sub) = RuneDefaultMacMenus.addTop(root: root, name: "Application")
                        tops.append((root, topEntry))
                        menu = sub
                    } else if let firstSub = root.items.first?.submenu {
                        menu = firstSub
                    } else {
                        let (topEntry, sub) = RuneDefaultMacMenus.addTop(root: root, name: "Application")
                        tops.append((root, topEntry))
                        menu = sub
                    }
                case .named(let name):
                    let root = RuneDefaultMacMenus.ensure(app)
                    if root.numberOfItems == 0 {
                        let (topEntry, _) = RuneDefaultMacMenus.addTop(root: root, name: "Application")
                        tops.append((root, topEntry))
                    }
                    let (newTop, sub) = RuneDefaultMacMenus.findOrCreateTop(root: root, name: name)
                    if let newTop {
                        tops.append((root, newTop))
                    }
                    menu = sub
                }

                if let anchor = desc.afterId, let idx = anchorIndex(in: menu, anchor: anchor, placed: placed, chained: chained) {
                    menu.insertItem(item, at: idx + 1)
                    chained.removeAll { $0.0 == anchor }
                    chained.append((anchor, item))
                } else if desc.location == .app {
                    let hasAbout = menu.items.first?.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
                    menu.insertItem(item, at: appIndex + (hasAbout ? 1 : 0))
                    appIndex += 1
                } else {
                    menu.addItem(item)
                }

                if !desc.isSeparator {
                    placed.append((desc.id, item))
                }
                entries.append((menu, item))
                if let target {
                    targets.append(target)
                }
            }
        }

        if let root = app.mainMenu {
            for top in root.items {
                if let sub = top.submenu {
                    RuneDefaultMacMenus.setLayoutDirection(sub)
                }
            }
        }
    }

    public func setJumpMenu(_ list: JumpList, onArgument: @escaping @MainActor (String) -> Void) {
        let app = NSApplication.shared
        guard (try? installDockHook(app)) != nil else { return }
        let menu = NSMenu()
        var newTargets: [RuneNativeMenuTarget] = []

        func appendItem(_ title: String, argument: String?) {
            if let argument {
                let target = RuneNativeMenuTarget(itemId: argument, enabled: true, keysFirst: false, handler: onArgument)
                let item = NSMenuItem(title: title, action: #selector(RuneNativeMenuTarget.runeMenuAction(_:)), keyEquivalent: "")
                item.target = target
                newTargets.append(target)
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        for task in list.tasks {
            appendItem(task.title, argument: task.argument)
        }
        for category in list.categories {
            if menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            appendItem(category.name, argument: nil)
            for item in category.items {
                appendItem(item.title, argument: item.argument)
            }
        }

        jumpMenu = menu
        jumpTargets = newTargets
    }

    public func currentDockMenu() -> NSMenu? {
        dockMenu ?? jumpMenu
    }

    private func anchorIndex(
        in menu: NSMenu,
        anchor: String,
        placed: [(String, NSMenuItem)],
        chained: [(String, NSMenuItem)]
    ) -> Int? {
        for (a, item) in chained where a == anchor {
            let idx = menu.index(of: item)
            if idx >= 0 { return idx }
        }
        for (id, item) in placed where id == anchor {
            let idx = menu.index(of: item)
            if idx >= 0 { return idx }
        }
        return menu.items.firstIndex { item in
            guard let act = item.action else { return false }
            return NSStringFromSelector(act) == anchor
        }
    }

    private func installDockHook(_ app: NSApplication) throws {
        guard let delegate = app.delegate else {
            throw MenuError.backend("missing application delegate")
        }
        let cls: AnyClass = type(of: delegate)
        let clsName = NSStringFromClass(cls)
        if dockHookedClassName == clsName { return }
        let selector = #selector(NSApplicationDelegate.applicationDockMenu(_:))
        if (delegate as AnyObject).responds(to: selector) {
            throw MenuError.backend("application delegate already supplies a Dock menu")
        }
        let imp: @convention(block) (AnyObject, NSApplication) -> NSMenu? = { _, _ in
            nonisolated(unsafe) var menu: NSMenu?
            MainActor.assumeIsolated {
                menu = RuneNativeMenuHost.shared.currentDockMenu()
            }
            return menu
        }
        let blockImp = imp_implementationWithBlock(imp)
        guard class_addMethod(cls, selector, blockImp, "@@:@") else {
            throw MenuError.backend("could not install Dock menu hook")
        }
        dockHookedClassName = clsName
        app.delegate = delegate
    }
}
#endif
