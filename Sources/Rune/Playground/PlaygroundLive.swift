import Foundation
import RuneMotion

// MARK: - Playground Chrome Controls & Widths (`playground.rs`, `widths.rs`)

public final class PlaygroundControls {
    public var filter: TextEdit = TextEdit()
    public var sidebarW: Float = PlaygroundConst.sidebar
    public var sideW: Float = PlaygroundConst.side
    internal var saveWidthsHook: ((Float, Float) -> Void)?

    public init(
        sidebarW: Float = PlaygroundConst.sidebar,
        sideW: Float = PlaygroundConst.side,
        saveWidthsHook: ((Float, Float) -> Void)? = nil
    ) {
        self.sidebarW = sidebarW
        self.sideW = sideW
        self.saveWidthsHook = saveWidthsHook
    }

    public func setWidths(sidebar: Float, side: Float) {
        if sidebar.isFinite && sidebar > 0.0 {
            sidebarW = min(max(sidebar, PlaygroundConst.sidebarMin), PlaygroundConst.sidebarMax).rounded()
        }
        if side.isFinite && side > 0.0 {
            sideW = min(max(side, PlaygroundConst.sideMin), PlaygroundConst.sideMax).rounded()
        }
    }

    public func saveWidths() {
        saveWidthsHook?(sidebarW, sideW)
    }

    public static func clampPair(sidebar: Float, side: Float, viewportW: Float) -> (Float, Float) {
        let minBar = PlaygroundConst.sidebarMin
        let minSide = PlaygroundConst.sideMin
        let stageMin = PlaygroundConst.stageMin
        let sep: Float = 2.0
        let sideMaxAvail = min(PlaygroundConst.sideMax, max(minSide, viewportW - minBar - stageMin - sep))
        let sW = min(max(side, minSide), sideMaxAvail)
        let barMaxAvail = min(PlaygroundConst.sidebarMax, max(minBar, viewportW - sW - stageMin - sep))
        let barW = min(max(sidebar, minBar), barMaxAvail)
        return (barW, sW)
    }
}

// MARK: - Tree Row (`playground/tree.rs`)

internal enum PlaygroundTreeRow: Equatable {
    case header(group: String, first: Int, depth: Int)
    case story(index: Int, depth: Int)

    static func headerKey(first: Int, depth: Int) -> String {
        depth == 0 ? "playground-group-\(first)" : "playground-group-\(first)-\(depth)"
    }
}

// MARK: - Page & Scene Descriptors (`playground/live.rs`)

internal struct PlaygroundSceneItem<State> {
    let name: String
    let apply: (inout State, inout Tx) -> Void
}

internal enum PlaygroundPageKind<State> {
    case live((State, inout Cx<State>) -> El<State>)
    case own(any AnyPlaygroundOwnStory<State>)
    case legacy(PlaygroundStory<State>)
}

internal struct PlaygroundPageItem<State> {
    let path: String
    let kind: PlaygroundPageKind<State>
    var stageLayout: PlaygroundStageLayout?
    var stageFrame: Vec2?
    var isOverlay: Bool
}

internal struct PlaygroundSceneStage<State> {
    var state: State
    var staged: PlaygroundStaged<State> = PlaygroundStaged<State>()
}

internal enum PlaygroundShowing<State> {
    case closed
    case open
    case scene(PlaygroundSceneStage<State>)

    var isOpen: Bool {
        if case .closed = self { return false }
        return true
    }
}

internal enum PlaygroundListNavResult {
    case pass
    case stay
    case filter
    case intoSide
    case intoStage
    case outOfSide
    case sideStep(Int)
    case request(PlaygroundRequest)
}

// MARK: - Live Playground Runtime State (`crates/rune/src/playground/live.rs`)

public final class PlaygroundLive<State> {
    internal var scenes: [PlaygroundSceneItem<State>] = []
    internal var pages: [PlaygroundPageItem<State>] = []
    internal var triggersByStory: [(storyIndex: Int, key: Character, label: String, action: (inout State, inout Play<State>) -> Void)] = []
    internal var sidesByStory: [(storyIndex: Int, side: PlaygroundSideKind<State>)] = []
    internal var stagesByStory: [(storyIndex: Int, layout: PlaygroundStageLayout, frame: Vec2?)] = []
    internal var variantsByStory: [(storyIndex: Int, name: String, apply: (inout State, inout Tx) -> Void)] = []
    internal var variantIndices: [Int] = []
    internal var sizes: [(name: String, size: Vec2)] = []
    internal var shortcut: Chord? = nil
    internal var shortcutMenu: Bool = true
    internal var showBar: Bool = true
    internal var makeState: () -> State
    internal var freshTransform: ((State) -> State)? = nil
    internal var keepTransform: ((State, inout State) -> Void)? = nil
    internal var appFreshPoll: ((inout State, Double, inout Play<State>) -> Bool)? = nil
    internal var keepSceneWhenClosed: Bool = false
    internal var appDarkReader: ((State) -> Bool)? = nil
    internal var typingPredicate: ((State) -> Bool)? = nil
    internal var groupOrder: [String] = []

    internal var order: [Int] = []
    public internal(set) var selected: Int = 0
    internal var header: String? = nil
    internal var folded: [String] = []
    internal var startFolded: Bool = false
    internal var loadFoldsHook: (() -> [String])? = nil
    internal var saveFoldsHook: (([String]) -> Void)? = nil
    internal var didLoadFolds: Bool = false

    internal var loadWidthsHook: (() -> (Float, Float)?)? = nil
    internal var didLoadWidths: Bool = false

    internal var keyboard = PlaygroundKeyboard()
    internal var showing: PlaygroundShowing<State> = .closed
    internal var ownedBoxes: [AnyObject?] = []
    internal var ownedStaged: [AnyObject?] = []

    public var controls: PlaygroundControls
    public internal(set) var dark: Bool? = nil
    public internal(set) var sizeIndex: Int = 0
    public internal(set) var reduceMotion: Bool = false

    internal var pending: [PlaygroundRequest] = []
    internal var pressedKeys: [KeyEvent] = []
    internal var pressing: Bool = false
    public internal(set) var played: Int = 0
    internal var now: Double = 0.0
    public internal(set) var generation: UInt64 = 1
    internal var appRootIndex: Int = 0
    internal var appTimeScale: Float = 1.0

    // Interactive resize drag state
    internal var dragStartSidebarW: Float = PlaygroundConst.sidebar
    internal var dragStartSideW: Float = PlaygroundConst.side
    internal var dragActiveSidebar: Bool = false
    internal var dragActiveSide: Bool = false

    internal init(
        makeState: @escaping () -> State,
        scenes: [PlaygroundSceneItem<State>],
        pages: [PlaygroundPageItem<State>],
        host: PlaygroundHost<State>?,
        appPoll: ((inout State, Double, inout Tx) -> Bool)? = nil
    ) {
        self.makeState = makeState
        self.scenes = scenes
        self.pages = pages

        let controls = PlaygroundControls()
        self.controls = controls

        if let host {
            self.sizes = host.presets.map { ($0.name, $0.size) }
            self.shortcut = host.shortcutChord
            self.shortcutMenu = host.liveSpec.shortcutMenuEnabled
            self.showBar = host.showBar
            self.freshTransform = host.freshTransform
            self.keepTransform = host.keepTransform
            self.keepSceneWhenClosed = host.liveSpec.keepsScene || host.keepTransform != nil
            self.appDarkReader = host.darkPredicate
            self.typingPredicate = host.typingPredicate
            self.appFreshPoll = host.liveSpec.pollStageHook ?? appPoll.map { hook in
                { state, t, play in hook(&state, t, &play.tx) }
            }
            self.groupOrder = host.groupOrder
            self.startFolded = host.startFolded
            self.loadFoldsHook = host.liveSpec.loadFoldsHook
            self.saveFoldsHook = host.liveSpec.saveFoldsHook
            self.loadWidthsHook = host.liveSpec.loadWidthsHook
            self.controls.saveWidthsHook = host.liveSpec.saveWidthsHook

            // Resolve pending story-path attachments onto scenes + pages
            self.resolveAttachments(host: host)
        } else {
            self.appFreshPoll = appPoll.map { hook in
                { state, t, play in hook(&state, t, &play.tx) }
            }
            self.sizes = [
                ("Mobile", Vec2(390, 844)),
                ("Tablet", Vec2(768, 1024)),
                ("Desktop", Vec2(1280, 800))
            ]
        }
        let total = self.scenes.count + self.pages.count
        self.variantIndices = Array(repeating: 0, count: total)
        self.ownedBoxes = Array(repeating: nil, count: self.pages.count)
        self.ownedStaged = Array(repeating: nil, count: self.pages.count)

        let listed: [Int] = (0..<total).filter { idx in
            if idx < self.scenes.count, let filter = host?.scenesFilter {
                return filter(self.scenes[idx].name)
            }
            return true
        }
        self.order = Self.computeTreeOrder(listed: listed, groupOrder: self.groupOrder) { idx in
            self.groupsOf(idx)
        }
        self.selected = self.order.first ?? 0
    }

    private func resolveAttachments(host: PlaygroundHost<State>) {
        let total = scenes.count + pages.count
        func findStoryIndex(_ query: String) -> Int? {
            if let exact = (0..<total).first(where: { path(of: $0) == query }) { return exact }
            if let ci = (0..<total).first(where: { path(of: $0).caseInsensitiveCompare(query) == .orderedSame }) { return ci }
            let targetSlug = PlaygroundSlug.slug(for: query)
            if !targetSlug.isEmpty {
                if let slugged = (0..<total).first(where: { PlaygroundSlug.slug(for: path(of: $0)) == targetSlug }) {
                    return slugged
                }
            }
            return (0..<total).first(where: { name(of: $0).caseInsensitiveCompare(query) == .orderedSame })
        }

        for att in host.liveSpec.sceneTriggers {
            guard let idx = findStoryIndex(att.story) else { continue }
            triggersByStory.append((idx, Character(att.key.lowercased()), att.label, att.action))
        }
        for att in host.liveSpec.sceneSides {
            guard let idx = findStoryIndex(att.story) else { continue }
            sidesByStory.append((idx, att.side))
        }
        for att in host.liveSpec.sceneStages {
            guard let idx = findStoryIndex(att.story) else { continue }
            stagesByStory.append((idx, att.layout, att.frame))
        }
        for att in host.liveSpec.sceneVariants {
            guard let idx = findStoryIndex(att.story) else { continue }
            variantsByStory.append((idx, att.name, att.apply))
        }
        for att in host.pendingTriggersSnapshot {
            guard let idx = findStoryIndex(att.story) else { continue }
            let action = att.trigger.action
            triggersByStory.append((idx, Character((att.trigger.key ?? "r").lowercased()), att.trigger.label, { st, play in
                action(&st, &play.tx)
            }))
        }
        for att in host.pendingVariantsSnapshot {
            guard let idx = findStoryIndex(att.story) else { continue }
            let apply = att.variant.apply
            variantsByStory.append((idx, att.variant.name, { st, _ in apply(&st) }))
        }
        for att in host.pendingSidesSnapshot {
            guard let idx = findStoryIndex(att.story) else { continue }
            sidesByStory.append((idx, .stage(att.view)))
        }
        for att in host.pendingStagesSnapshot {
            guard let idx = findStoryIndex(att.story) else { continue }
            let layout: PlaygroundStageLayout = att.config.centered ? .center : .fill
            stagesByStory.append((idx, layout, att.config.size))
        }

        // Also seed legacy PlaygroundStory attachments directly at their page index
        for (offset, p) in pages.enumerated() {
            let storyIdx = scenes.count + offset
            if case .legacy(let legacy) = p.kind {
                for trig in legacy.triggers {
                    if let k = trig.key {
                        let action = trig.action
                        triggersByStory.append((storyIdx, Character(k.lowercased()), trig.label, { state, play in
                            action(&state, &play.tx)
                        }))
                    }
                }
                for v in legacy.variants {
                    let apply = v.apply
                    variantsByStory.append((storyIdx, v.name, { state, _ in apply(&state) }))
                }
                if let sideView = legacy.sideView {
                    sidesByStory.append((storyIdx, .stage(sideView)))
                }
                if legacy.stageConfig.size != nil || !legacy.stageConfig.centered {
                    let layout: PlaygroundStageLayout = legacy.stageConfig.centered ? .center : .fill
                    stagesByStory.append((storyIdx, layout, legacy.stageConfig.size))
                }
            }
        }
    }

    // MARK: - Story Metadata & Tree Order (`live.rs`, `tree.rs`)

    public var count: Int { scenes.count + pages.count }
    public var isOpen: Bool { showing.isOpen }
    public var region: PlaygroundRegion { keyboard.region }
    public var hasPending: Bool { !pending.isEmpty }

    public var pendingSwapsStage: Bool {
        pending.contains { $0.swapsStage }
    }

    public var pendingReplaysOnly: Bool {
        !pending.isEmpty && pending.allSatisfy {
            if case .replay = $0 { return true }
            return false
        }
    }

    public func path(of index: Int) -> String {
        if index < scenes.count {
            return scenes[index].name
        }
        let pIdx = index - scenes.count
        if pages.indices.contains(pIdx) {
            return pages[pIdx].path
        }
        return ""
    }

    private static func splitPath(_ path: String, defaultGroup: String) -> (group: String, name: String) {
        if let slash = path.lastIndex(of: "/") {
            let g = String(path[..<slash])
            let n = String(path[path.index(after: slash)...])
            return (g.isEmpty ? defaultGroup : g, n)
        }
        return (defaultGroup, path)
    }

    public func group(of index: Int) -> String {
        let defaultGroup = index < scenes.count ? "Scenes" : "Pages"
        return Self.splitPath(path(of: index), defaultGroup: defaultGroup).group
    }

    public func name(of index: Int) -> String {
        Self.splitPath(path(of: index), defaultGroup: "").name
    }

    public func groupsOf(_ index: Int) -> [String] {
        let g = group(of: index)
        var out: [String] = []
        var searchStart = g.startIndex
        while let slash = g[searchStart...].firstIndex(of: "/") {
            out.append(String(g[..<slash]))
            searchStart = g.index(after: slash)
        }
        out.append(g)
        return out
    }

    internal static func parentGroup(of group: String) -> String? {
        guard let slash = group.lastIndex(of: "/") else { return nil }
        return String(group[..<slash])
    }

    private static func computeTreeOrder(
        listed: [Int],
        groupOrder: [String],
        groupsOf: (Int) -> [String]
    ) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(listed.count)

        func gather(_ items: [Int], depth: Int) {
            var runs: [(group: String?, inside: [Int])] = []
            for i in items {
                let gs = groupsOf(i)
                let key: String? = depth < gs.count ? gs[depth] : nil
                if let runIdx = runs.firstIndex(where: { $0.group == key }) {
                    runs[runIdx].inside.append(i)
                } else {
                    runs.append((key, [i]))
                }
            }
            if depth == 0 && !groupOrder.isEmpty {
                runs.sort { a, b in
                    let pa = a.group.flatMap { groupOrder.firstIndex(of: $0) } ?? Int.max
                    let pb = b.group.flatMap { groupOrder.firstIndex(of: $0) } ?? Int.max
                    return pa < pb
                }
            }
            for (grp, inside) in runs {
                if grp != nil {
                    gather(inside, depth: depth + 1)
                } else {
                    out.append(contentsOf: inside)
                }
            }
        }

        gather(listed, depth: 0)
        return out
    }

    // MARK: - Filter, Folds & Rows (`tree.rs`, `folds.rs`)

    public var query: String {
        controls.filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func clearFilter() -> Bool {
        guard !controls.filter.text.isEmpty else { return false }
        controls.filter.clear()
        return true
    }

    public func matches(_ index: Int) -> Bool {
        let q = query
        if q.isEmpty { return true }
        let p = path(of: index).lowercased()
        let words = q.lowercased().split { $0.isWhitespace }
        return words.allSatisfy { p.contains($0) }
    }

    public func firstMatch() -> Int? {
        if header == nil && selected < count && matches(selected) {
            return nil
        }
        return order.first { matches($0) }
    }

    internal func firstShown() -> Int? {
        for row in rows() {
            if case .story(let i, _) = row { return i }
        }
        return nil
    }

    public func isFolded(_ group: String) -> Bool {
        query.isEmpty && folded.contains(group)
    }

    public func isIn(_ index: Int, group: String) -> Bool {
        let own = self.group(of: index)
        return own == group || own.hasPrefix(group + "/")
    }

    public func countIn(_ group: String) -> Int {
        order.filter { isIn($0, group: group) && matches($0) }.count
    }

    private func firstIn(_ group: String) -> Int {
        order.first { isIn($0, group: group) } ?? 0
    }

    internal func rows() -> [PlaygroundTreeRow] {
        var out: [PlaygroundTreeRow] = []
        var openGroups: [String] = []
        for i in order where matches(i) {
            let groups = groupsOf(i)
            var same = 0
            while same < openGroups.count && same < groups.count && openGroups[same] == groups[same] {
                same += 1
            }
            if same < openGroups.count {
                openGroups.removeLast(openGroups.count - same)
            }
            for depth in same..<groups.count {
                let anyParentFolded = (0..<depth).contains { isFolded(groups[$0]) }
                if !anyParentFolded {
                    out.append(.header(group: groups[depth], first: firstIn(groups[depth]), depth: depth))
                }
                openGroups.append(groups[depth])
            }
            let anyFolded = groups.contains { isFolded($0) }
            if !anyFolded {
                out.append(.story(index: i, depth: groups.count))
            }
        }
        return out
    }

    private func hiddenBy(_ groups: [String]) -> String? {
        groups.first { isFolded($0) }
    }

    internal func settle() {
        guard isOpen else { return }
        let hider: String?
        if let h = header {
            var around: [String] = []
            var cur = Self.parentGroup(of: h)
            while let up = cur {
                around.append(up)
                cur = Self.parentGroup(of: up)
            }
            around.reverse()
            hider = hiddenBy(around)
        } else if selected < count {
            hider = hiddenBy(groupsOf(selected))
        } else {
            hider = nil
        }
        if let g = hider {
            header = g
        }
    }

    public func allGroups() -> [String] {
        var out: [String] = []
        for i in order {
            for g in groupsOf(i) where !out.contains(g) {
                out.append(g)
            }
        }
        return out
    }

    private func loadFoldsIfNeeded() {
        guard !didLoadFolds else { return }
        didLoadFolds = true
        if let load = loadFoldsHook {
            let names = load()
            folded = allGroups().filter { g in
                names.contains(g) != startFolded
            }
        } else if startFolded {
            folded = allGroups()
        }
    }

    private func refold(_ mutate: (inout [String]) -> Void) {
        let before = folded
        mutate(&folded)
        guard folded != before, let save = saveFoldsHook else { return }
        let names: [String]
        if startFolded {
            names = allGroups().filter { !folded.contains($0) }
        } else {
            names = folded
        }
        save(names)
    }

    private func reveal(_ index: Int) {
        guard index < count else { return }
        let gs = groupsOf(index)
        refold { f in
            f.removeAll { gs.contains($0) }
        }
    }

    // MARK: - Widths (`widths.rs`)

    private func loadWidthsIfNeeded() {
        guard !didLoadWidths else { return }
        didLoadWidths = true
        if let loaded = loadWidthsHook?() {
            controls.setWidths(sidebar: loaded.0, side: loaded.1)
        }
    }

    public func widths(viewportW: Float) -> (sidebar: Float, side: Float) {
        PlaygroundControls.clampPair(sidebar: controls.sidebarW, side: controls.sideW, viewportW: viewportW)
    }

    // MARK: - Current Page / Scene / Variants / Triggers / Layout

    internal var currentPage: PlaygroundPageItem<State>? {
        let idx = selected - scenes.count
        guard idx >= 0, pages.indices.contains(idx) else { return nil }
        return pages[idx]
    }

    internal var currentOwn: (any AnyPlaygroundOwnStory<State>, AnyObject, AnyObject?)? {
        let idx = selected - scenes.count
        guard idx >= 0, pages.indices.contains(idx),
              case .own(let story) = pages[idx].kind,
              let box = ownedBoxes[idx] else {
            return nil
        }
        return (story, box, ownedStaged[idx])
    }

    internal var currentScene: PlaygroundSceneStage<State>? {
        get {
            if case .scene(let s) = showing { return s }
            return nil
        }
        set {
            if let s = newValue {
                showing = .scene(s)
            }
        }
    }

    public func hasTriggers(_ index: Int) -> Bool {
        if index < scenes.count {
            return triggersByStory.contains { $0.storyIndex == index }
        }
        let pIdx = index - scenes.count
        if pages.indices.contains(pIdx) {
            switch pages[pIdx].kind {
            case .own(let own):
                return !own.triggerDescriptors.isEmpty
            case .legacy(let legacy):
                return !legacy.triggers.isEmpty || triggersByStory.contains { $0.storyIndex == index }
            case .live:
                return triggersByStory.contains { $0.storyIndex == index }
            }
        }
        return false
    }

    public func variants() -> [String] {
        guard selected < count else { return [] }
        if selected < scenes.count {
            return variantsByStory.filter { $0.storyIndex == selected }.map(\.name)
        }
        if let page = currentPage {
            switch page.kind {
            case .own(let own):
                return own.variantNames
            case .legacy:
                return variantsByStory.filter { $0.storyIndex == selected }.map(\.name)
            case .live:
                return []
            }
        }
        return []
    }

    public func variantIndex() -> Int {
        guard variantIndices.indices.contains(selected) else { return 0 }
        return variantIndices[selected]
    }

    public func triggers() -> [(key: Character, label: String)] {
        guard selected < count else { return [] }
        if case .live = currentPage?.kind { return [] }
        var keys: [(key: Character, label: String)]
        if let (own, _, _) = currentOwn {
            keys = own.triggerDescriptors
        } else if selected < scenes.count {
            keys = triggersByStory.filter { $0.storyIndex == selected }.map { ($0.key, $0.label) }
        } else if case .own(let own) = currentPage?.kind {
            keys = own.triggerDescriptors
        } else {
            keys = []
        }
        let replay: (key: Character, label: String)
        if let idx = keys.firstIndex(where: { Character($0.key.lowercased()) == "r" }) {
            replay = keys.remove(at: idx)
        } else {
            replay = (Character("r"), "Replay")
        }
        keys.insert(replay, at: 0)
        return keys
    }

    public func layoutOfSelected() -> PlaygroundStageLayout {
        if let stage = stagesByStory.last(where: { $0.storyIndex == selected }) {
            return stage.layout
        }
        if let page = currentPage, let layout = page.stageLayout {
            return layout
        }
        return .center
    }

    public func frameOfSelected() -> Vec2? {
        if let stage = stagesByStory.last(where: { $0.storyIndex == selected }) {
            return stage.frame
        }
        return currentPage?.stageFrame
    }

    public func variantKey(_ letter: Character) -> PlaygroundRequest? {
        guard let scalar = letter.unicodeScalars.first,
              scalar.value >= 49 && scalar.value <= 57 else { return nil }
        let n = Int(scalar.value - 49)
        return n < variants().count ? .variant(n) : nil
    }

    public func triggerRequest(for letter: Character) -> PlaygroundRequest? {
        let lower = Character(letter.lowercased())
        guard triggers().contains(where: { Character($0.key.lowercased()) == lower }) else { return nil }
        return lower == "r" ? .replay : .trigger(lower)
    }

    internal func findStory(_ query: String) -> Int? {
        if let exact = order.first(where: { path(of: $0) == query || name(of: $0) == query }) {
            return exact
        }
        if let ci = order.first(where: {
            path(of: $0).caseInsensitiveCompare(query) == .orderedSame ||
                name(of: $0).caseInsensitiveCompare(query) == .orderedSame
        }) {
            return ci
        }
        let targetSlug = PlaygroundSlug.slug(for: query)
        if let bySlug = order.first(where: {
            let s = PlaygroundSlug.slug(for: path(of: $0))
            return s == query || (!targetSlug.isEmpty && s == targetSlug)
        }) {
            return bySlug
        }
        return nil
    }

    public func pickVariant(_ nameOrIndex: String, for storyIdx: Int) throws -> Int {
        let list: [String]
        if storyIdx < scenes.count {
            list = variantsByStory.filter { $0.storyIndex == storyIdx }.map(\.name)
        } else if let pIdx = Optional(storyIdx - scenes.count), pages.indices.contains(pIdx) {
            switch pages[pIdx].kind {
            case .own(let own): list = own.variantNames
            case .legacy: list = variantsByStory.filter { $0.storyIndex == storyIdx }.map(\.name)
            case .live: list = []
            }
        } else {
            list = []
        }

        if let oneBased = Int(nameOrIndex), oneBased >= 1, oneBased <= list.count {
            return oneBased - 1
        }
        if let match = list.firstIndex(where: { $0.caseInsensitiveCompare(nameOrIndex) == .orderedSame }) {
            return match
        }
        let storyName = path(of: storyIdx)
        throw PlaygroundLookupError.unknownVariant(name: nameOrIndex, story: storyName, available: list)
    }

    // MARK: - Request Queue & Application (`live.rs`, `open.rs`)

    public func enqueue(_ requests: [PlaygroundRequest]) {
        pending.append(contentsOf: requests)
    }

    public func enqueue(_ request: PlaygroundRequest) {
        pending.append(request)
    }

    public func isShortcut(_ event: KeyEvent) -> Bool {
        guard !shortcutMenu else { return false }
        return shortcut?.matches(event) ?? false
    }

    @discardableResult
    public func applyPending(at now: Double, appState: inout State) -> (applied: Bool, tx: Tx) {
        self.now = now
        var tx = Tx()
        guard !pending.isEmpty else { return (false, tx) }

        loadWidthsIfNeeded()
        loadFoldsIfNeeded()

        let batch = pending
        pending.removeAll()
        var changed = false
        var wantsInstant = false

        for req in batch {
            switch req {
            case .open:
                if !isOpen {
                    openOrSelect(selected, variant: nil, rebuild: true, shouldReveal: startFolded, appState: &appState, tx: &tx)
                    changed = true
                    wantsInstant = true
                }
            case .openAt(let query, let variant):
                if let idx = findStory(query) {
                    if let vStr = variant, let vIdx = try? pickVariant(vStr, for: idx) {
                        variantIndices[idx] = vIdx
                    }
                    header = nil
                    openOrSelect(idx, variant: variant, rebuild: true, appState: &appState, tx: &tx)
                    changed = true
                    wantsInstant = true
                } else {
                    if !isOpen {
                        openOrSelect(selected, variant: nil, rebuild: true, shouldReveal: startFolded, appState: &appState, tx: &tx)
                        changed = true
                        wantsInstant = true
                    }
                }
            case .close:
                if isOpen {
                    keep(&appState)
                    close(&appState)
                    changed = true
                    wantsInstant = true
                }
            case .toggle:
                if isOpen {
                    keep(&appState)
                    close(&appState)
                } else {
                    openOrSelect(selected, variant: nil, rebuild: true, shouldReveal: startFolded, appState: &appState, tx: &tx)
                }
                changed = true
                wantsInstant = true
            case .select(let idx):
                guard idx >= 0 && idx < count else { continue }
                if !isOpen || header != nil || selected != idx {
                    header = nil
                    openOrSelect(idx, variant: nil, rebuild: false, appState: &appState, tx: &tx)
                    changed = true
                    wantsInstant = true
                }
            case .replay:
                if isOpen {
                    if case .live = currentPage?.kind {
                        changed = true
                    } else {
                        openOrSelect(selected, variant: nil, rebuild: true, shouldReveal: false, appState: &appState, tx: &tx)
                        changed = true
                        wantsInstant = true
                    }
                }
            case .keep:
                if isOpen {
                    keep(&appState)
                    changed = true
                }
            case .variant(let vIdx):
                if variantIndices.indices.contains(selected) {
                    let countV = variants().count
                    if vIdx >= 0 && vIdx < countV {
                        variantIndices[selected] = vIdx
                        if isOpen {
                            if case .live = currentPage?.kind {
                                // Live pages do not stage or replay.
                            } else {
                                openOrSelect(selected, variant: nil, rebuild: true, shouldReveal: false, appState: &appState, tx: &tx)
                            }
                        }
                        changed = true
                        wantsInstant = true
                    }
                }
            case .trigger(let ch):
                if isOpen {
                    runTrigger(ch, appState: &appState, tx: &tx)
                    changed = true
                }
            case .dark(let on):
                dark = on
                changed = true
                wantsInstant = true
            case .size(let idx):
                sizeIndex = (sizes.isEmpty ? 0 : idx % (sizes.count + 1))
                changed = true
                wantsInstant = true
            case .reduceMotion(let on):
                reduceMotion = on
                changed = true
                wantsInstant = true
            case .header(let grp):
                header = grp
                changed = true
                wantsInstant = true
            case .fold(let grp, let explicit):
                foldGroup(grp, folded: explicit)
                settle()
                changed = true
                wantsInstant = true
            }
        }
        settle()
        if wantsInstant {
            tx.instant()
        }
        return (changed, tx)
    }

    private func foldGroup(_ group: String, folded explicit: Bool?) {
        let currentlyFolded = self.folded.contains(group)
        let target = explicit ?? !currentlyFolded
        if target == currentlyFolded { return }
        refold { list in
            if target {
                if !list.contains(group) { list.append(group) }
            } else {
                list.removeAll { $0 == group }
            }
        }
    }

    private func stopCurrentStaged() {
        if case .scene(let s) = showing {
            s.staged.reset(at: now)
        }
        let idx = selected - scenes.count
        if idx >= 0, pages.indices.contains(idx),
           case .own(let own) = pages[idx].kind {
            own.stopStaged(ownedStaged[idx])
        }
    }

    private func openOrSelect(_ index: Int, variant: String?, rebuild: Bool, shouldReveal: Bool = true, appState: inout State, tx: inout Tx) {
        if isOpen {
            keep(&appState)
        }
        stopCurrentStaged()
        selected = min(max(0, index), max(0, count - 1))
        if shouldReveal {
            header = nil
            reveal(selected)
        }
        generation &+= 1

        if selected < scenes.count {
            var stageState = withSceneClock(SceneClock(now: 0.0, dt: 0.0)) { () -> State in
                var s = freshTransform?(appState) ?? makeState()
                var initTx = Tx()
                scenes[selected].apply(&s, &initTx)
                let vs = variantsByStory.filter { $0.storyIndex == selected }
                let vIdx = variantIndices.indices.contains(selected) ? variantIndices[selected] : 0
                if vs.indices.contains(vIdx) {
                    vs[vIdx].apply(&s, &initTx)
                }
                return s
            }
            let staged = PlaygroundStaged<State>()
            staged.now = now
            staged.needsImmediatePoll = (appFreshPoll != nil)
            if appFreshPoll != nil {
                tx.wakeAfter(0.0)
            }
            // Run optional 'r' trigger if declared
            if let trig = triggersByStory.first(where: { $0.storyIndex == selected && Character($0.key.lowercased()) == "r" }) {
                var play = Play<State>(tx: tx, now: now)
                trig.action(&stageState, &play)
                tx = play.tx
                staged.absorb(from: play, baseNow: now)
                drainImmediateSceneSteps(state: &stageState, staged: staged, tx: &tx)
            }
            showing = .scene(PlaygroundSceneStage(state: stageState, staged: staged))
            return
        }

        let pIdx = selected - scenes.count
        guard pages.indices.contains(pIdx) else {
            showing = .open
            return
        }

        switch pages[pIdx].kind {
        case .live:
            showing = .open
        case .own(let own):
            let needFresh = rebuild || ownedBoxes[pIdx] == nil
            let box: AnyObject
            let staged: AnyObject
            if needFresh {
                box = withSceneClock(SceneClock(now: 0.0, dt: 0.0)) { () -> AnyObject in
                    let b = own.makeInitialBox(fromReal: appState)
                    var initTx = Tx()
                    let vIdx = variantIndices.indices.contains(selected) ? variantIndices[selected] : 0
                    _ = own.applyVariant(index: vIdx, box: b, tx: &initTx)
                    return b
                }
                staged = own.makeStaged()
                if let sched = staged as? AnyPlaygroundStaged, sched.nextDue(after: now) != nil {
                    tx.wakeAfter(0.0)
                }
                ownedBoxes[pIdx] = box
                ownedStaged[pIdx] = staged
            } else {
                box = ownedBoxes[pIdx]!
                staged = ownedStaged[pIdx] ?? own.makeStaged()
                ownedStaged[pIdx] = staged
            }
            if let resettable = staged as? AnyPlaygroundResettableStaged {
                resettable.setNow(now)
            }
            showing = .open
            if needFresh {
                let res = own.runTrigger(key: "r", box: box, staged: staged, tx: &tx)
                if !res.pressedKeys.isEmpty {
                    pressedKeys.append(contentsOf: res.pressedKeys)
                }
            }
        case .legacy(let legacy):
            var stageState = withSceneClock(SceneClock(now: 0.0, dt: 0.0)) { () -> State in
                var s = legacy.makeState?() ?? freshTransform?(appState) ?? makeState()
                var initTx = Tx()
                let vs = variantsByStory.filter { $0.storyIndex == selected }
                let vIdx = variantIndices.indices.contains(selected) ? variantIndices[selected] : 0
                if vs.indices.contains(vIdx) {
                    vs[vIdx].apply(&s, &initTx)
                }
                return s
            }
            let staged = PlaygroundStaged<State>()
            staged.now = now
            staged.needsImmediatePoll = (appFreshPoll != nil)
            if appFreshPoll != nil {
                tx.wakeAfter(0.0)
            }
            if let trig = triggersByStory.first(where: { $0.storyIndex == selected && Character($0.key.lowercased()) == "r" }) {
                var play = Play<State>(tx: tx, now: now)
                trig.action(&stageState, &play)
                tx = play.tx
                staged.absorb(from: play, baseNow: now)
                drainImmediateSceneSteps(state: &stageState, staged: staged, tx: &tx)
            }
            showing = .scene(PlaygroundSceneStage(state: stageState, staged: staged))
        }
    }

    private func drainImmediateSceneSteps(state: inout State, staged: PlaygroundStaged<State>, tx: inout Tx) {
        var steps = 0
        while steps < PlaygroundConst.maxStepsPerFrame,
              let due = staged.popNextDue(at: staged.now) {
            steps += 1
            switch due.action {
            case .step(let fn):
                var play = Play<State>(tx: tx, now: due.dueAt)
                fn(&state, &play)
                tx = play.tx
                staged.absorb(from: play, baseNow: due.dueAt)
            case .press(let ev):
                pressedKeys.append(ev)
            }
        }
    }

    private func keep(_ appState: inout State) {
        guard keepSceneWhenClosed, case .scene(let scene) = showing else { return }
        if let keepFn = keepTransform {
            keepFn(scene.state, &appState)
        } else {
            appState = scene.state
        }
    }

    private func close(_ appState: inout State) {
        stopCurrentStaged()
        showing = .closed
        header = nil
        controls.filter = TextEdit()
        variantIndices = Array(repeating: 0, count: count)
        ownedBoxes = Array(repeating: nil, count: pages.count)
        ownedStaged = Array(repeating: nil, count: pages.count)
        generation &+= 1
        _ = moved(.closed)
    }

    private func runTrigger(_ key: Character, appState: inout State, tx: inout Tx) {
        let lower = Character(key.lowercased())
        if case .scene(var scene) = showing {
            if let trig = triggersByStory.first(where: { $0.storyIndex == selected && Character($0.key.lowercased()) == lower }) {
                var play = Play<State>(tx: tx, now: scene.staged.now)
                trig.action(&scene.state, &play)
                tx = play.tx
                scene.staged.absorb(from: play, baseNow: scene.staged.now)
                drainImmediateSceneSteps(state: &scene.state, staged: scene.staged, tx: &tx)
                showing = .scene(scene)
            }
            return
        }
        if let (own, box, staged) = currentOwn {
            let res = own.runTrigger(key: lower, box: box, staged: staged, tx: &tx)
            if !res.pressedKeys.isEmpty {
                pressedKeys.append(contentsOf: res.pressedKeys)
            }
            return
        }
        if let trig = triggersByStory.first(where: { $0.storyIndex == selected && Character($0.key.lowercased()) == lower }) {
            var play = Play<State>(tx: tx, now: now)
            trig.action(&appState, &play)
            tx = play.tx
            for item in play.scheduled {
                if case .press(let ev) = item.action, item.delay == 0 {
                    pressedKeys.append(ev)
                }
            }
        }
    }

    // MARK: - Stage Polling & Timed Steps (`stage.rs`)

    public var polls: Bool {
        guard isOpen else { return false }
        if !pressedKeys.isEmpty { return true }
        if case .scene(let s) = showing {
            return appFreshPoll != nil || !s.staged.isEmpty
        }
        if let (own, _, staged) = currentOwn {
            let schedNonEmpty = (staged as? AnyPlaygroundStaged).map { !$0.isEmpty } ?? false
            return own.hasPollHook || schedNonEmpty
        }
        return false
    }

    @discardableResult
    internal func pollStage(at now: Double, appState: inout State, tx: inout Tx) -> (changed: Bool, wakeAfter: Double?) {
        self.now = now
        guard isOpen else { return (false, nil) }

        if case .scene(var scene) = showing {
            scene.staged.now = now
            scene.staged.needsImmediatePoll = false
            var changed = false
            if let pollFn = appFreshPoll {
                var play = Play<State>(tx: tx, now: now)
                let res = pollFn(&scene.state, now, &play)
                tx = play.tx
                if res || tx.isForceCommitRequested { changed = true }
                scene.staged.absorb(from: play, baseNow: now)
            }
            var steps = 0
            while steps < PlaygroundConst.maxStepsPerFrame,
                  let due = scene.staged.popNextDue(at: now) {
                steps += 1
                changed = true
                switch due.action {
                case .step(let fn):
                    var play = Play<State>(tx: tx, now: due.dueAt)
                    fn(&scene.state, &play)
                    tx = play.tx
                    scene.staged.absorb(from: play, baseNow: due.dueAt)
                case .press(let ev):
                    pressedKeys.append(ev)
                }
            }
            let wakeAfter = scene.staged.nextDue(after: now).map { max(0.0, $0 - now) }
            showing = .scene(scene)
            return (changed, wakeAfter)
        }

        if let (own, box, staged) = currentOwn {
            let res = own.runPollAndDueSteps(box: box, staged: staged, now: now, tx: &tx)
            if !res.pressedKeys.isEmpty {
                pressedKeys.append(contentsOf: res.pressedKeys)
            }
            return (res.changed, res.wakeAfter)
        }

        return (false, nil)
    }

    internal func takePressed() -> [KeyEvent] {
        guard !pressedKeys.isEmpty else { return [] }
        let out = pressedKeys
        pressedKeys.removeAll()
        return out
    }

    // MARK: - Keyboard Navigation & Region Tracking (`nav.rs`, `region.rs`)

    internal var sideActive: Bool {
        keyboard.slotFocused
    }

    internal func sawFocus(_ focus: String?) -> Bool {
        keyboard.saw(focus)
    }

    @discardableResult
    internal func moved(_ event: PlaygroundMoved) -> Bool {
        keyboard.step(event)
    }

    internal func regionAt(focusedKey: String?, focusedUnderSide: Bool, focusedUnderStage: Bool) -> PlaygroundRegion? {
        if focusedKey == PlaygroundConst.filterKey {
            return .list
        }
        if focusedUnderSide {
            return .side
        }
        if focusedUnderStage {
            return .stage
        }
        return nil
    }

    internal func nav(_ event: KeyEvent, region: PlaygroundRegion) -> PlaygroundListNavResult {
        let modifiers = ChordBits.held(event.mods, platform: .current) & ~ChordBits.shift
        let primary = modifiers == ChordBits.primary
        guard isOpen, modifiers == 0 || primary, region != .stage else { return .pass }

        let letter: Character? = {
            if case .text(let s) = event.key, !primary, s.count == 1, let c = s.first {
                return Character(c.lowercased())
            }
            if case .space = event.key, !primary {
                return " "
            }
            return nil
        }()

        let inSide = (region == .side)
        if inSide {
            switch event.key {
            case .tab, .escape, .arrowLeft:
                return .outOfSide
            case .arrowUp where !primary:
                return .sideStep(-1)
            case .arrowDown where !primary:
                return .sideStep(1)
            default:
                break
            }
            if let c = letter, let req = variantKey(c) {
                return .request(req)
            }
        }

        if let c = letter, !(inSide && c == " "), let req = triggerRequest(for: c) {
            return .request(req)
        }
        if inSide { return .pass }
        if letter == "/" { return .filter }

        let listRes = listNav(event, letter: letter, primary: primary)
        if case .pass = listRes, !primary {
            switch event.key {
            case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .enter:
                return .stay
            default:
                break
            }
        }
        return listRes
    }

    private func listNav(_ event: KeyEvent, letter: Character?, primary: Bool) -> PlaygroundListNavResult {
        let m = event.mods
        if event.key == .tab {
            return m.shift ? .intoStage : .intoSide
        }

        let currentRows = rows()
        func isStoryRow(_ r: PlaygroundTreeRow) -> Bool {
            if case .story = r { return true }
            return false
        }
        guard let lastStory = currentRows.last(where: isStoryRow) else {
            return .pass
        }
        let at = currentRows.firstIndex { row in
            switch (row, header) {
            case (.header(let g, _, _), .some(let h)): return g == h
            case (.story(let i, _), .none): return i == selected
            default: return false
            }
        }
        let n = currentRows.count
        let firstStoryIdx = currentRows.firstIndex(where: isStoryRow) ?? 0

        let to: PlaygroundTreeRow
        switch (event.key, letter, header) {
        case (.arrowUp, _, _) where !primary && !query.isEmpty && (at == nil || at! <= firstStoryIdx):
            return .filter
        case (.arrowUp, _, _) where primary:
            to = currentRows.first(where: isStoryRow) ?? lastStory
        case (.arrowDown, _, _) where primary:
            to = lastStory
        case _ where primary:
            return .pass
        case (.arrowUp, _, _):
            let idx = at.map { ($0 + n - 1) % n } ?? 0
            to = currentRows[idx]
        case (.arrowDown, _, _):
            let idx = at.map { ($0 + 1) % n } ?? 0
            to = currentRows[idx]
        case (_, .some("j"), _):
            let from = at ?? 0
            var found: PlaygroundTreeRow?
            for k in 1...n {
                let candidate = currentRows[(from + k) % n]
                if isStoryRow(candidate) { found = candidate; break }
            }
            to = found ?? lastStory
        case (_, .some("k"), _):
            let from = at ?? 0
            var found: PlaygroundTreeRow?
            for k in 1...n {
                let candidate = currentRows[(from + k * (n - 1)) % n]
                if isStoryRow(candidate) { found = candidate; break }
            }
            to = found ?? lastStory
        case (.arrowLeft, _, .some(let g)) where !isFolded(g) && query.isEmpty:
            return .request(.fold(g, true))
        case (.arrowLeft, _, .some(let g)):
            if let up = Self.parentGroup(of: g) {
                return .request(.header(up))
            }
            return .pass
        case (.arrowLeft, _, .none) where selected < count:
            return .request(.header(group(of: selected)))
        case (.arrowRight, _, .some(let g)) where !m.shift && isFolded(g):
            return .request(.fold(g, false))
        case (.arrowRight, _, .some):
            guard !m.shift else { return .pass }
            if let a = at, a + 1 < currentRows.count {
                let next = currentRows[a + 1]
                if case .header(_, _, let d) = next, d == 0 {
                    return .pass
                }
                to = next
            } else {
                return .pass
            }
        case (.enter, _, .some(let g)):
            return .request(.fold(g, nil))
        case (.arrowRight, _, .none) where !m.shift:
            return .intoSide
        default:
            return .pass
        }

        switch to {
        case .header(let g, _, _): return .request(.header(g))
        case .story(let i, _): return .request(.select(i))
        }
    }

    internal var hasSideKeysForSelected: Bool {
        if showingSceneOrLegacy {
            return sidesByStory.contains {
                if $0.storyIndex == selected, case .keys = $0.side { return true }
                return false
            }
        }
        if let (own, _, _) = currentOwn {
            return own.hasSideKeys
        }
        return false
    }

    private var showingSceneOrLegacy: Bool {
        if case .scene = showing { return true }
        return false
    }

    internal func dispatchSideKey(_ event: KeyEvent, tx: inout Tx) -> Bool {
        guard isOpen else { return false }
        var took = false
        if case .scene(var scene) = showing {
            if let match = sidesByStory.first(where: { $0.storyIndex == selected }),
               case .keys(let onKey, _) = match.side {
                took = onKey(&scene.state, event, &tx)
                showing = .scene(scene)
            }
        } else if let (own, box, _) = currentOwn {
            took = own.dispatchSideKey(event, box: box, tx: &tx)
        }
        return took || event.key == .arrowLeft
    }

    internal func stageHears(_ appState: State) -> Bool {
        if showingSceneOrLegacy { return true }
        if case .live = currentPage?.kind { return true }
        return false
    }

    internal func typing(appState: State) -> Bool {
        guard isOpen, let pred = typingPredicate else { return false }
        switch showing {
        case .scene(let s): return pred(s.state)
        case .open:
            if case .live = currentPage?.kind { return pred(appState) }
            return false
        case .closed:
            return false
        }
    }

    internal func isDark(appState: State, systemDark: Bool) -> Bool {
        if let reader = appDarkReader {
            return reader(appState)
        }
        return systemDark
    }

    // MARK: - Scene / Story State Access (`testing.rs` / `runtime/playground.rs`)

    internal func currentStageState<T>(as type: T.Type = T.self) -> T? {
        if case .scene(let s) = showing {
            return s.state as? T
        }
        if let (_, box, _) = currentOwn, let typed = box as? PlaygroundStateBox<T> {
            return typed.value
        }
        return nil
    }

    internal func withKeyState(appState: inout State, _ body: (inout State) -> Bool) -> Bool? {
        if !isOpen {
            return body(&appState)
        }
        if case .scene(var scene) = showing {
            let handled = body(&scene.state)
            showing = .scene(scene)
            return handled
        }
        if case .live = currentPage?.kind {
            return body(&appState)
        }
        return nil
    }

    internal func withErasedStageState(
        tx: inout Tx,
        _ body: (inout Any, inout Tx) -> Void
    ) -> Bool {
        if case .scene(var scene) = showing {
            var boxed: Any = scene.state
            body(&boxed, &tx)
            if let updated = boxed as? State {
                scene.state = updated
            }
            showing = .scene(scene)
            return true
        }
        if let (own, box, _) = currentOwn {
            return own.withErasedState(box: box, tx: &tx, body)
        }
        return false
    }
}
