import Foundation
import RuneMotion

// MARK: - PlaygroundHost Parity Builders

extension PlaygroundHost {
    /// Registers an isolated `Story<P>` with its own state type `P` (`Playground::story`).
    @discardableResult
    public func story<P>(_ story: Story<P>) -> Self {
        precondition(story.isCompatible(with: State.self), "derives from another app state")
        let erased = TypedPlaygroundOwnStory<P, State>(story)
        liveSpec.orderedPages.append(
            PlaygroundPageItem(
                path: story.path,
                kind: .own(erased),
                stageLayout: story.stageLayout,
                stageFrame: story.stageFrame,
                isOverlay: story.overlayBackdrop != nil
            )
        )
        let copy = PlaygroundStory<State>(
            path: story.path,
            triggers: story.triggers.map { t in
                PlaygroundTrigger<State>(key: t.key, label: t.label) { _, _ in }
            },
            variants: story.variants.map { v in
                PlaygroundVariant<State>(name: v.name) { _ in }
            },
            stageConfig: PlaygroundStageConfig(
                size: story.stageFrame,
                centered: (story.stageLayout ?? .center) != .fill
            ),
            view: { _, _, _ in el() }
        )
        _ = self.story(copy)
        return self
    }

    /// Adds a choreography trigger (`Play<State>`) onto a scene or page (`Playground::trigger`).
    @discardableResult
    public func triggerPlay(
        _ scene: String,
        key: Character,
        label: String,
        play action: @escaping (inout State, inout Play<State>) -> Void
    ) -> Self {
        liveSpec.sceneTriggers.append((scene, Character(key.lowercased()), label, action))
        return self
    }

    /// Adds a `Tx`-only trigger onto a scene or page (`Playground::trigger_tx`).
    @discardableResult
    public func triggerTx(
        _ scene: String,
        key: Character,
        label: String,
        action: @escaping (inout State, inout Tx) -> Void
    ) -> Self {
        triggerPlay(scene, key: key, label: label) { state, play in
            action(&state, &play.tx)
        }
    }

    /// Attaches a side inspector receiving `(stageState, appState, cx)` onto a scene (`Playground::side_real`).
    @discardableResult
    public func sideReal(
        _ scene: String,
        view: @escaping (State, State, inout Cx<State>) -> El<State>
    ) -> Self {
        liveSpec.sceneSides.append((scene, .real(view)))
        return self
    }

    /// Attaches a keyboard-controlled side view onto a scene (`Playground::side_keys`).
    @discardableResult
    public func sideKeys(
        _ scene: String,
        onKey: @escaping (inout State, KeyEvent, inout Tx) -> Bool,
        view: @escaping (State, Bool, inout Cx<State>) -> El<State>
    ) -> Self {
        liveSpec.sceneSides.append((scene, .keys(onKey: onKey, view: view)))
        return self
    }

    /// Configures a scene's stage layout and optional fixed size (`Playground::stage`).
    @discardableResult
    public func stage(
        _ scene: String,
        _ layout: PlaygroundStageLayout,
        _ frame: Vec2? = nil
    ) -> Self {
        liveSpec.sceneStages.append((scene, layout, frame))
        return self
    }

    /// Adds a named variant with a `Tx` parameter onto a scene (`Playground::variant`).
    @discardableResult
    public func variant(
        _ scene: String,
        name: String,
        applyTx: @escaping (inout State, inout Tx) -> Void
    ) -> Self {
        liveSpec.sceneVariants.append((scene, name, applyTx))
        return self
    }

    /// Sets viewport size presets in the footer size menu (`Playground::sizes`).
    @discardableResult
    public func sizes(_ newSizes: [(String, Vec2)]) -> Self {
        liveSpec.hasCustomSizes = true
        return viewportPresets(newSizes.map { ViewportPreset(name: $0.0, size: $0.1) })
    }

    /// Persists folded group names (`Playground::folds`).
    @discardableResult
    public func folds(
        load: @escaping () -> [String],
        save: @escaping ([String]) -> Void
    ) -> Self {
        liveSpec.loadFoldsHook = load
        liveSpec.saveFoldsHook = save
        return self
    }

    /// Persists sidebar & side column widths (`Playground::widths`).
    @discardableResult
    public func widths(
        load: @escaping () -> (Float, Float)?,
        save: @escaping (Float, Float) -> Void
    ) -> Self {
        liveSpec.loadWidthsHook = load
        liveSpec.saveWidthsHook = save
        return self
    }

    /// Polls stage state with `Play<State>` choreography when a scene is active (`Playground::poll`).
    @discardableResult
    public func poll(
        _ hook: @escaping (inout State, Double, inout Play<State>) -> Bool
    ) -> Self {
        liveSpec.pollStageHook = hook
        return self
    }

    /// Polls stage state with `(state, play)` when a scene is active (`Playground::poll`).
    @discardableResult
    public func poll(
        _ hook: @escaping (inout State, inout Play<State>) -> Bool
    ) -> Self {
        liveSpec.pollStageHook = { state, _, play in hook(&state, &play) }
        return self
    }

    /// Controls whether the View menu includes the Playground toggle item (`Playground::shortcut_menu`).
    @discardableResult
    public func shortcutMenu(_ enabled: Bool) -> Self {
        liveSpec.shortcutMenuEnabled = enabled
        return self
    }

    /// Preserves stage edits back into app state when keeping/closing a scene (`Playground::keep`).
    @discardableResult
    public func keepScene(_ enabled: Bool = true) -> Self {
        liveSpec.keepsScene = enabled
        return self
    }
}

// MARK: - Attachment (`playground.rs::attach`)

public enum PlaygroundAttach {
    /// Attaches `PlaygroundLive<State>` onto `runtime` if permitted by environment & `host.isEnabled`.
    @discardableResult
    public static func attach<State>(
        runtime: Runtime<State>,
        host: PlaygroundHost<State>?,
        scenes: [String: (inout State, inout Tx) -> Void],
        sceneOrder: [String] = [],
        makeState: @escaping () -> State,
        appId: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        open: String? = nil,
        openRequested: Bool = false,
        variant: String? = nil,
        windowed: Bool = false,
        forceAttach: Bool = false
    ) throws -> PlaygroundLive<State>? {
        if let h = host, !h.isEnabled && !openRequested && open == nil {
            return nil
        }
        if host == nil && scenes.isEmpty && !openRequested && open == nil {
            return nil
        }
        if !forceAttach && !openRequested && open == nil && (!windowed || PlaygroundEnv.hiddenByEnv(env)) {
            return nil
        }

        var orderedNames: [String] = []
        orderedNames.reserveCapacity(scenes.count)
        for name in sceneOrder where scenes[name] != nil && !orderedNames.contains(name) {
            orderedNames.append(name)
        }
        for name in scenes.keys.sorted() where !orderedNames.contains(name) {
            orderedNames.append(name)
        }
        let sceneItems: [PlaygroundSceneItem<State>] = orderedNames.compactMap { name in
            guard let apply = scenes[name] else { return nil }
            return PlaygroundSceneItem(name: name, apply: apply)
        }

        var pageItems: [PlaygroundPageItem<State>] = []
        if let host {
            var seenPaths: Set<String> = []
            for p in host.liveSpec.orderedPages {
                if case .legacy = p.kind,
                   let updated = host.stories.first(where: { $0.path == p.path }) {
                    let layout: PlaygroundStageLayout? = (updated.stageConfig.size != nil || !updated.stageConfig.centered)
                        ? (updated.stageConfig.centered ? .center : .fill)
                        : nil
                    pageItems.append(
                        PlaygroundPageItem(
                            path: updated.path,
                            kind: .legacy(updated),
                            stageLayout: layout,
                            stageFrame: updated.stageConfig.size,
                            isOverlay: p.isOverlay
                        )
                    )
                } else {
                    pageItems.append(p)
                }
                seenPaths.insert(p.path)
            }
            for s in host.stories where !s.isScene && !seenPaths.contains(s.path) {
                let layout: PlaygroundStageLayout? = (s.stageConfig.size != nil || !s.stageConfig.centered)
                    ? (s.stageConfig.centered ? .center : .fill)
                    : nil
                pageItems.append(
                    PlaygroundPageItem(
                        path: s.path,
                        kind: .legacy(s),
                        stageLayout: layout,
                        stageFrame: s.stageConfig.size,
                        isOverlay: false
                    )
                )
            }
        }

        let live = PlaygroundLive<State>(
            makeState: makeState,
            scenes: sceneItems,
            pages: pageItems,
            host: host,
            appPoll: runtime.poll
        )
        live.appTimeScale = runtime.cxSettings.viewTimeScale

        if windowed && !forceAttach && live.loadWidthsHook == nil {
            let prefsId = appId ?? "com.rune.app"
            live.loadWidthsHook = {
                let prefs = Prefs.open(appId: prefsId, environment: env)
                guard let sb: Float = prefs.get(PlaygroundConst.sidebarWidthPrefKey),
                      let sd: Float = prefs.get(PlaygroundConst.sideWidthPrefKey) else {
                    return nil
                }
                return (sb, sd)
            }
            live.controls.saveWidthsHook = { sb, sd in
                let prefs = Prefs.open(appId: prefsId, environment: env)
                if abs(sb - PlaygroundConst.sidebar) < 0.5 {
                    try? prefs.remove(PlaygroundConst.sidebarWidthPrefKey)
                } else {
                    try? prefs.set(PlaygroundConst.sidebarWidthPrefKey, value: sb)
                }
                if abs(sd - PlaygroundConst.side) < 0.5 {
                    try? prefs.remove(PlaygroundConst.sideWidthPrefKey)
                } else {
                    try? prefs.set(PlaygroundConst.sideWidthPrefKey, value: sd)
                }
            }
        }

        live.shortcutMenu = windowed && live.shortcutMenu && {
            #if os(macOS)
            return true
            #else
            return false
            #endif
        }()

        runtime.playgroundLiveStorage = live

        if let openName = open {
            try runtime.openPlayground(at: openName, variant: variant)
        } else if openRequested {
            if let variant, live.count > 0 {
                _ = try live.pickVariant(variant, for: live.selected)
                try runtime.openPlayground(at: live.path(of: live.selected), variant: variant)
            } else {
                live.enqueue(.open)
                runtime.applyPlaygroundIfNeeded(at: runtime.currentTime)
                runtime.settlePlayground()
            }
        }

        return live
    }
}

// MARK: - Runtime Bridge & Lifecycle (`crates/rune/src/runtime/playground.rs` + `playground/testing.rs`)

extension Runtime {
    internal var playgroundLive: PlaygroundLive<State>? {
        playgroundLiveStorage as? PlaygroundLive<State>
    }

    public static func isPlaygroundStageKey(_ key: String?) -> Bool {
        guard let key else { return false }
        if key == "playground-stage" { return true }
        let prefix = "playground-stage-"
        guard key.hasPrefix(prefix) else { return false }
        let suffix = key.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isASCII) && UInt64(suffix) != nil
    }

    internal static func stageElementIndex(in all: [ElementInfo], key: String) -> Int? {
        for (i, info) in all.enumerated() where !info.moving {
            let matchesName = (info.key == key || info.path == key)
            guard matchesName else { continue }
            if isInsideStage(index: i, in: all) {
                return i
            }
        }
        // Fallback: include moving elements if non-moving didn't match
        for (i, info) in all.enumerated() {
            let matchesName = (info.key == key || info.path == key)
            guard matchesName else { continue }
            if isInsideStage(index: i, in: all) {
                return i
            }
        }
        return nil
    }

    private static func isInsideStage(index: Int, in all: [ElementInfo]) -> Bool {
        var cur: Int? = index
        while let idx = cur, idx >= 0, idx < all.count {
            if isPlaygroundStageKey(all[idx].key) {
                return true
            }
            cur = all[idx].parentIndex
        }
        return false
    }

    // MARK: - Root / Under Helpers

    internal func isNodeUnder(_ index: Int, predicate: (String) -> Bool) -> Bool {
        var cur: Int? = index
        while let idx = cur, idx >= 0, idx < flatNodes.count {
            if let k = flatNodes[idx].key, predicate(k) {
                return true
            }
            cur = flatNodes[idx].parentIndex
        }
        return false
    }

    internal func playgroundAppRootNodeIndex() -> Int {
        guard let live = playgroundLive else { return 0 }
        return min(max(0, live.appRootIndex), max(0, flatNodes.count - 1))
    }

    internal func findPlaygroundAppRoot() {
        guard let live = playgroundLive else { return }
        func isWrapper(_ key: String?) -> Bool {
            guard let k = key else { return false }
            return k == "playground-closed" || k == "playground-margin" || Self.isPlaygroundStageKey(k)
        }
        if let idx = flatNodes.firstIndex(where: { node in
            guard node.key != "playground-margin", let pIdx = node.parentIndex else { return false }
            return isWrapper(flatNodes[pIdx].key)
        }) {
            live.appRootIndex = idx
        } else {
            live.appRootIndex = 0
        }
    }

    // MARK: - Request Latching & Commit Application

    internal func latchPlaygroundRequests(from tx: inout Tx) {
        if let pgReqs = tx.runtimeActions.removeValue(forKey: "playgroundRequests") as? [PlaygroundTxRequest],
           !pgReqs.isEmpty {
            playgroundRequests.append(contentsOf: pgReqs)
            if let live = playgroundLive {
                var mapped: [PlaygroundRequest] = []
                mapped.reserveCapacity(pgReqs.count)
                for req in pgReqs {
                    switch req {
                    case .open:
                        mapped.append(.open)
                    case let .openAt(story, variant):
                        mapped.append(.openAt(story, variant: variant))
                    case .close:
                        mapped.append(.close)
                    case .replay:
                        mapped.append(.replay)
                    case .trigger(let ch):
                        let lower = Character(ch.lowercased())
                        mapped.append(lower == "r" ? .replay : .trigger(lower))
                    case .toggle:
                        mapped.append(.toggle)
                    case .keep:
                        mapped.append(.keep)
                    }
                }
                live.enqueue(mapped)
                forceInitialSettle = true
                dirtyCommit(at: currentTime)
            } else if let pg = playgroundHost, pg.isEnabled {
                for req in pgReqs {
                    switch req {
                    case .open:
                        pg.open()
                    case let .openAt(story, variant):
                        do {
                            try pg.openAt(story: story, variant: variant)
                            if let fresh = pg.freshTransform {
                                state = fresh(state)
                            }
                            if let v = pg.currentVariant {
                                v.apply(&state)
                            }
                            dirtyCommit(at: currentTime)
                        } catch {
                            pg.open()
                        }
                    case .close:
                        pg.close()
                    case .replay:
                        var followTx = Tx()
                        pg.replay(on: &state, tx: &followTx)
                        applyTx(followTx, at: currentTime)
                    case .trigger(let ch):
                        var followTx = Tx()
                        if pg.fireTrigger(ch, on: &state, tx: &followTx) {
                            applyTx(followTx, at: currentTime)
                        }
                    case .toggle:
                        if pg.isOpen { pg.close() } else { pg.open() }
                    case .keep:
                        pg.close()
                    }
                }
            }
        }

        if let internalReqs = tx.runtimeActions.removeValue(forKey: "playgroundInternalRequests") as? [PlaygroundRequest],
           !internalReqs.isEmpty,
           let live = playgroundLive {
            live.enqueue(internalReqs)
            forceInitialSettle = true
            dirtyCommit(at: currentTime)
        }
    }

    internal func applyPlaygroundIfNeeded(at now: Double) {
        guard let live = playgroundLive else { return }
        syncPlaygroundRegion()
        guard live.hasPending else { return }

        let swaps = live.pendingSwapsStage
        let focusedUnderSide: Bool = {
            guard let fp = focusedPath, let fIdx = nodeByPath[fp] else { return false }
            return isNodeUnder(fIdx) { $0 == "playground-side" }
        }()
        let keepSideFocus = live.pendingReplaysOnly && focusedUnderSide
        let wasOpen = live.isOpen

        let (applied, tx) = live.applyPending(at: now, appState: &state)
        guard applied else { return }

        if swaps {
            leavePlaygroundStage(wasOpen: wasOpen, keepSideFocus: keepSideFocus, at: now)
        }
        // playground.rs:53: applying the playground's pending change marks the state dirty.
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true, why: CommitWhy.dirty)
        needsCommit = true
        commitWhyPending |= CommitWhy.dirty
        if live.swapsResetSettle(swaps) {
            forceInitialSettle = true
        }
    }

    private func leavePlaygroundStage(wasOpen: Bool, keepSideFocus: Bool, at now: Double) {
        guard let live = playgroundLive else { return }
        if wasOpen {
            cxSettings.setTimeScale(live.appTimeScale, at: now)
        } else {
            live.appTimeScale = cxSettings.viewTimeScale
        }
        if !keepSideFocus {
            focusedPath = nil
            focusedKey = nil
        }
        pressedPath = nil
        pressedKey = nil
        clearTitlebarPress()
        hoveredPath = nil
        hoveredKey = nil
        dragFilesLeave(at: now)
    }

    internal func buildPlaygroundViewIfAttached(cx: inout Cx<State>) -> El<State> {
        guard let live = playgroundLive else {
            return view(state, &cx)
        }
        return live.buildView(appState: state, appView: view, cx: &cx, viewport: viewport)
    }

    internal func reconcilePlaygroundAfterCommit(at now: Double) {
        guard playgroundLive != nil else { return }
        findPlaygroundAppRoot()
        syncPlaygroundSideFocus()
        syncPlaygroundRegion()
    }

    // MARK: - Poll & Choreographed Key Presses (`stage.rs`, `runtime/frame.rs`)

    internal func pollPlaygroundIfNeeded(at now: Double) {
        guard let live = playgroundLive, live.polls else { return }
        commitInputApartFromFramePoll(at: now, polls: true)
        var tx = Tx()
        let (changed, wakeAfter) = live.pollStage(at: now, appState: &state, tx: &tx)
        if let wakeAfter {
            let due = now + wakeAfter
            if nextWakeDeadline == nil || due < nextWakeDeadline! {
                nextWakeDeadline = due
            }
        }
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: changed, why: changed ? CommitWhy.poll : 0)
        // The playground's poll is a frame poll too (frame.rs:542, `why |= CommitWhy::POLL`).
        if changed { framePollChanged() }

        let keys = live.takePressed()
        if !keys.isEmpty { commitPolledChangeApart(at: now, routed: true) }
        for ev in keys {
            _ = routePlaygroundStageKey(ev, at: now)
            live.played += 1
        }
    }

    @discardableResult
    internal func routePlaygroundStageKey(_ event: KeyEvent, at now: Double) -> Bool {
        guard let live = playgroundLive, live.isOpen else {
            return keyDown(event, isRepeat: false, at: now)
        }
        let savedRegion = live.region
        let savedPath = focusedPath
        let savedKey = focusedKey
        let focusOutsideStage: Bool = {
            guard let fp = focusedPath, let fIdx = nodeByPath[fp] else { return false }
            return !isNodeUnder(fIdx) { Self.isPlaygroundStageKey($0) }
        }()
        if focusOutsideStage {
            focusedPath = nil
            focusedKey = nil
        }
        _ = live.moved(.hold(.stage))

        live.pressing = true
        let took = keyDown(event, isRepeat: false, at: now)
        live.pressing = false

        let focusMovedIntoStage: Bool = {
            guard let fp = focusedPath, let fIdx = nodeByPath[fp] else { return false }
            return isNodeUnder(fIdx) { Self.isPlaygroundStageKey($0) }
        }()
        let back: String?
        if focusOutsideStage && !focusMovedIntoStage {
            focusedPath = savedPath
            focusedKey = savedKey
            back = savedPath
        } else if focusMovedIntoStage {
            back = focusedPath
        } else {
            back = nil
        }
        _ = live.moved(.resume(savedRegion, back: back))
        syncPlaygroundSideFocus()
        return took
    }

    // MARK: - Region Sync, Focus & Navigation (`nav.rs`, `region.rs`, `runtime/playground.rs`)

    internal func syncPlaygroundRegion() {
        guard let live = playgroundLive else { return }
        guard !live.sawFocus(focusedPath) else { return }
        let focusedUnderSide: Bool
        let focusedUnderStage: Bool
        let focusedOnHoverHighlight: Bool
        if let fp = focusedPath, let fIdx = nodeByPath[fp] {
            focusedUnderSide = isNodeUnder(fIdx) { $0 == "playground-side" }
            focusedUnderStage = isNodeUnder(fIdx) { Self.isPlaygroundStageKey($0) }
            focusedOnHoverHighlight = flatNodes[fIdx].el.focusHighlightColor != nil
        } else {
            focusedUnderSide = false
            focusedUnderStage = false
            focusedOnHoverHighlight = false
        }
        let nextRegion: PlaygroundRegion? = focusedOnHoverHighlight ? nil : live.regionAt(
            focusedKey: focusedKey,
            focusedUnderSide: focusedUnderSide,
            focusedUnderStage: focusedUnderStage
        )
        if live.moved(.focus(focus: focusedPath, region: nextRegion)) {
            needsCommit = true
            commitWhyPending |= CommitWhy.dirty
        }
    }

    internal func syncPlaygroundSideFocus() {
        guard let live = playgroundLive else { return }
        let active: Bool = {
            guard let fp = focusedPath, let fIdx = nodeByPath[fp] else { return false }
            return flatNodes[fIdx].key?.hasPrefix("playground-slot-") == true
        }()
        if live.moved(.slot(active)) {
            needsCommit = true
            commitWhyPending |= CommitWhy.dirty
        }
    }

    private func playgroundSidePaths() -> [String] {
        flatNodes.indices.compactMap { idx in
            guard canFocusIndex(idx), isNodeUnder(idx, predicate: { $0 == "playground-side" }) else {
                return nil
            }
            return flatNodes[idx].path
        }
    }

    private func toPlaygroundList(at now: Double) {
        guard let live = playgroundLive else { return }
        focusedPath = nil
        focusedKey = nil
        syncPlaygroundSideFocus()
        _ = live.moved(.give(.list, seen: nil))
        dirtyCommit(at: now, why: CommitWhy.input)
    }

    @discardableResult
    internal func playgroundNav(_ event: KeyEvent, isRepeat: Bool, at now: Double) -> Bool {
        guard let live = playgroundLive else { return false }
        if live.hasPending {
            applyPlaygroundIfNeeded(at: now)
        }
        if live.pressing {
            return false
        }

        if live.isShortcut(event) {
            if !isRepeat {
                live.enqueue(.toggle)
                applyPlaygroundIfNeeded(at: now)
                dirtyCommit(at: now, why: CommitWhy.input)
            }
            return true
        }

        if live.typing(appState: state), let globalOnKey {
            var tx = Tx()
            let handled = live.withKeyState(appState: &state) { keyState in
                globalOnKey(&keyState, event, &tx)
            } ?? false
            if handled {
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
                return true
            }
        }

        guard live.isOpen else { return false }
        syncPlaygroundRegion()

        if let fPath = focusedPath,
           focusedInputElement(at: fPath)?.handlers.editLens != nil {
            return filterKey(event, at: now)
        }

        if live.region == .side && live.sideActive {
            if event.key == .escape || event.key == .tab {
                toPlaygroundList(at: now)
                return true
            }
            var tx = Tx()
            if live.dispatchSideKey(event, tx: &tx) {
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
        }

        switch live.nav(event, region: live.region) {
        case .pass:
            return false
        case .stay:
            return true
        case .filter:
            if let fNode = flatNodes.first(where: { $0.key == PlaygroundConst.filterKey }) {
                focusedPath = fNode.path
                focusedKey = fNode.key
                focusVisible = true
                if live.moved(.give(.list, seen: focusedPath)) || true {
                    dirtyCommit(at: now, why: CommitWhy.input)
                }
            }
            return true
        case .intoSide:
            let paths = playgroundSidePaths()
            if let firstPath = paths.first, let idx = nodeByPath[firstPath] {
                focusedPath = firstPath
                focusedKey = flatNodes[idx].key
                focusVisible = true
                _ = live.moved(.give(.side, seen: focusedPath))
                syncPlaygroundSideFocus()
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
            return true
        case .intoStage:
            if let stageIdx = flatNodes.indices.first(where: { idx in
                canFocusIndex(idx) && isNodeUnder(idx, predicate: { Self.isPlaygroundStageKey($0) })
            }) {
                focusedPath = flatNodes[stageIdx].path
                focusedKey = flatNodes[stageIdx].key
                focusVisible = true
            } else {
                focusedPath = nil
                focusedKey = nil
            }
            _ = live.moved(.give(.stage, seen: focusedPath))
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        case .outOfSide:
            toPlaygroundList(at: now)
            return true
        case .sideStep(let delta):
            let paths = playgroundSidePaths()
            guard !paths.isEmpty else { return true }
            let cur = focusedPath.flatMap { paths.firstIndex(of: $0) } ?? 0
            let next = (cur + delta + paths.count) % paths.count
            let nextPath = paths[next]
            if let idx = nodeByPath[nextPath] {
                focusedPath = nextPath
                focusedKey = flatNodes[idx].key
                focusVisible = true
                syncPlaygroundSideFocus()
                dirtyCommit(at: now, why: CommitWhy.input)
            }
            return true
        case .request(let req):
            live.enqueue(req)
            applyPlaygroundIfNeeded(at: now)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }
    }

    private func filterKey(_ event: KeyEvent, at now: Double) -> Bool {
        guard let live = playgroundLive,
              focusedKey == PlaygroundConst.filterKey,
              event.mods == .none else {
            return false
        }
        if event.key == .escape {
            if live.clearFilter() {
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
            toPlaygroundList(at: now)
            return true
        }
        if event.key == .arrowDown {
            if let first = live.firstShown() {
                live.enqueue(.select(first))
                applyPlaygroundIfNeeded(at: now)
            }
            toPlaygroundList(at: now)
            return true
        }
        if event.key == .enter {
            if let first = live.firstMatch() {
                live.enqueue(.select(first))
                applyPlaygroundIfNeeded(at: now)
            }
            toPlaygroundList(at: now)
            return true
        }
        return false
    }

    @discardableResult
    internal func playgroundKey(_ event: KeyEvent, at now: Double) -> Bool {
        guard let live = playgroundLive,
              live.isOpen,
              event.key == .escape,
              event.mods == .none else {
            return false
        }
        syncPlaygroundRegion()
        if live.region != .list {
            toPlaygroundList(at: now)
        } else {
            live.enqueue(.close)
            applyPlaygroundIfNeeded(at: now)
            dirtyCommit(at: now, why: CommitWhy.input)
        }
        return true
    }

    internal func playgroundPointerDown(at pos: Vec2, at now: Double) {
        guard let live = playgroundLive, live.isOpen else { return }
        let (sidebarW, sideW) = live.widths(viewportW: viewport.x)
        let target: PlaygroundRegion
        if pos.x < sidebarW + 1.0 {
            target = .list
        } else if pos.x >= viewport.x - sideW {
            target = .side
        } else {
            target = .stage
        }
        if live.moved(.give(target, seen: focusedPath)) {
            dirtyCommit(at: now, why: CommitWhy.input)
        }
    }

    internal func playgroundAppKey(_ event: KeyEvent, at now: Double) -> Bool? {
        guard let live = playgroundLive, let globalOnKey else { return nil }
        if !live.isOpen {
            var tx = makeTx(at: now)
            let handled = globalOnKey(&state, event, &tx)
            Tx.took(handled, &tx)
            if handled {
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
            }
            return handled
        }
        var tx = makeTx(at: now)
        let result = live.withKeyState(appState: &state) { keyState in
            globalOnKey(&keyState, event, &tx)
        }
        guard let handled = result else { return false }
        Tx.took(handled, &tx)
        if handled {
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
        }
        return handled
    }

    internal func playgroundNextWakeDeadline(after now: Double) -> Double? {
        guard let live = playgroundLive, live.isOpen else { return nil }
        if case .scene(let scene) = live.showing,
           let next = scene.staged.nextDue(after: now) {
            return max(next, now)
        }
        if let (_, _, staged) = live.currentOwn,
           let sched = staged as? AnyPlaygroundStaged,
           let next = sched.nextDue(after: now) {
            return max(next, now)
        }
        return nil
    }

    internal func playgroundWithErasedState(
        _ body: (inout Any, inout Tx) -> Void,
        at now: Double,
        why: UInt16 = CommitWhy.input
    ) -> Bool {
        // Handle Playground size picker target cleanly without colliding with AppState
        var testTx = Tx()
        var chromeMarker: Any = PlaygroundSizePopupTarget()
        body(&chromeMarker, &testTx)
        let hasChromeRequests =
            (testTx.runtimeActions["playgroundInternalRequests"] != nil) ||
            (testTx.runtimeActions["playgroundRequests"] != nil) ||
            testTx.isForceCommitRequested ||
            testTx.settleRequested
        if let live = playgroundLive, hasChromeRequests || !(chromeMarker is PlaygroundSizePopupTarget) {
            applyTx(testTx, at: now, why: why)
            live.enqueue([])
            applyPlaygroundIfNeeded(at: now)
            dirtyCommit(at: now, why: why)
            return true
        }

        if let live = playgroundLive, live.isOpen {
            var tx = Tx()
            if live.withErasedStageState(tx: &tx, body) {
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: true, why: why)
                dirtyCommit(at: now, why: why)
                return true
            }
        }
        return false
    }

    // MARK: - Testing Helpers (`playground/testing.rs`)

    /// Queues a request and renders two zero-dt frames so stage & immediate `'r'` steps settle.
    internal func settlePlayground() {
        applyPlaygroundIfNeeded(at: currentTime)
        _ = frame(at: currentTime)
        _ = frame(at: currentTime)
    }

    /// Opens the playground at `story` (path, name, or slug) and optional `variant` (1-based index or name).
    public func openPlayground(at story: String? = nil, variant: String? = nil) throws {
        guard let live = playgroundLive else {
            throw PlaygroundLookupError.unknownStory(name: story ?? "", available: [])
        }
        if let story {
            guard let idx = live.findStory(story) else {
                let avail = (0..<live.count).map { live.path(of: $0) }
                throw PlaygroundLookupError.unknownStory(name: story, available: avail)
            }
            if let variant {
                _ = try live.pickVariant(variant, for: idx)
            }
            live.enqueue(.openAt(story, variant: variant))
        } else {
            live.enqueue(.open)
        }
        settlePlayground()
    }

    /// Fires trigger `key` on the open story and runs two zero-dt settle frames.
    public func playgroundTrigger(_ key: Character) throws {
        guard let live = playgroundLive, live.isOpen else {
            throw PlaygroundLookupError.unknownStory(name: String(key), available: [])
        }
        let lower = Character(key.lowercased())
        guard let req = live.triggerRequest(for: lower) else {
            let avail = live.triggers().map { "\($0.key) (\($0.label))" }
            throw PlaygroundLookupError.unknownVariant(name: String(key), story: live.path(of: live.selected), available: avail)
        }
        live.enqueue(req)
        settlePlayground()
    }

    /// Closes the playground UI and settles cleanly back to the app view.
    public func closePlayground() {
        guard let live = playgroundLive else { return }
        live.enqueue(.close)
        settlePlayground()
    }

    /// Returns the open stage's isolated state (scene `State` or `Story<P>` state `P`), or `nil` when closed / live page.
    public func playgroundState<T>(as type: T.Type = T.self) -> T? {
        guard let live = playgroundLive, live.isOpen else { return nil }
        return live.currentStageState(as: type)
    }

    /// Returns the `ElementInfo` for `key` inside the active playground stage only.
    internal func playgroundDispatchFocus(
        _ focused: Bool,
        hook: (inout State, Bool, inout Tx) -> Void,
        at now: Double
    ) -> Bool {
        guard let live = playgroundLive, live.isOpen, var scene = live.currentScene else {
            return false
        }
        var tx = Tx()
        hook(&scene.state, focused, &tx)
        live.currentScene = scene
        applyTx(tx, at: now, why: CommitWhy.dirty)
        dirtyCommit(at: now)
        return true
    }

    public func playgroundElement(_ key: String) -> ElementInfo? {
        guard let live = playgroundLive, live.isOpen else { return nil }
        let all = elements()
        guard let idx = Self.stageElementIndex(in: all, key: key) else { return nil }
        return all[idx]
    }

    /// Number of key presses executed by `Play.press` across the playground's lifetime.
    public var playgroundPlayedKeys: Int {
        playgroundLive?.played ?? 0
    }
}

private extension PlaygroundLive {
    func swapsResetSettle(_ swaps: Bool) -> Bool {
        swaps
    }
}
