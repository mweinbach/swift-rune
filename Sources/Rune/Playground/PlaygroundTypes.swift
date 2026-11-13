import Foundation
import RuneMotion

// MARK: - Constants (`crates/rune/src/playground.rs` / `widths.rs` / `list.rs` / `stage.rs`)

public enum PlaygroundConst {
    public static let bar: Float = 26.0
    public static let sidebar: Float = 200.0
    public static let side: Float = 264.0
    public static let header: Float = 38.0
    public static let band: Float = 28.0
    public static let row: Float = 28.0
    public static let control: Float = 24.0
    public static let filterKey: String = "playground-filter"
    public static let indent: Float = 12.0
    public static let field: Float = 32.0
    public static let scrollMargin: Float = 24.0
    public static let sidebarMin: Float = 150.0
    public static let sidebarMax: Float = 520.0
    public static let sideMin: Float = 180.0
    public static let sideMax: Float = 560.0
    public static let stageMin: Float = 200.0
    public static let dueSlack: Double = 1e-6
    public static let maxStepsPerFrame: Int = 64
    public static let sidebarWidthPrefKey: String = "playground_sidebar_w"
    public static let sideWidthPrefKey: String = "playground_side_w"
}

// MARK: - Stage Layout & Story Choreography (`crates/rune/src/playground/stage.rs`)

/// How a playground story's stage sits in its column (`playground::Stage`).
public enum PlaygroundStageLayout: Sendable, Equatable {
    /// Centered in the stage area (`Stage::Center`).
    case center
    /// Scrollable vertically with `PlaygroundConst.scrollMargin` padding (`Stage::Scroll`).
    case scroll
    /// Sized to fill the stage area without a frame outline (`Stage::Fill`).
    case fill
}

public typealias PlaygroundStage = PlaygroundStageLayout

internal enum PlaygroundScheduledAction<X> {
    case step((inout X, inout Play<X>) -> Void)
    case press(KeyEvent)
}

internal struct PlaygroundScheduledEntry<X> {
    let dueAt: Double
    let seq: UInt64
    let action: PlaygroundScheduledAction<X>
}

/// Time-and-input choreography passed to `Story.trigger` and `Story.poll` (`playground::Play`).
public struct Play<X> {
    public var tx: Tx
    internal var clockNow: Double
    internal var scheduled: [(delay: Double, action: PlaygroundScheduledAction<X>)] = []
    internal var cleared: Bool = false

    public init(tx: Tx = Tx(), now: Double = 0.0) {
        self.tx = tx
        self.clockNow = now
    }

    /// Logical clock time when this step was due (`Play::now`).
    public func now() -> Double {
        clockNow
    }

    /// Cancels all previously scheduled steps on this stage clock (`Play::clear`).
    public mutating func clear() {
        cleared = true
        scheduled.removeAll()
    }

    /// Schedules a closure `delay` seconds from the current stage clock (`Play::after`).
    public mutating func after(_ delay: Double, _ body: @escaping (inout X, inout Play<X>) -> Void) {
        scheduled.append((max(0.0, delay), .step(body)))
    }

    /// Schedules a closure `milliseconds` ms from the current stage clock.
    public mutating func afterMs(_ milliseconds: Double, _ body: @escaping (inout X, inout Play<X>) -> Void) {
        after(milliseconds / 1000.0, body)
    }

    /// Schedules a key press to be delivered to the stage `delay` seconds from now (`Play::press`).
    public mutating func press(after delay: Double = 0.0, _ key: Key, mods: Mods = .none) {
        scheduled.append((max(0.0, delay), .press(KeyEvent(key: key, mods: mods))))
    }

    /// Schedules an unmodified key press right now (alias matching Rust `p.press(...)`).
    public mutating func press(_ key: Key, mods: Mods = .none) {
        press(after: 0.0, key, mods: mods)
    }

    /// Schedules a character key press right now (`Play::press('a')`).
    public mutating func press(_ ch: Character, mods: Mods = .none, after delay: Double = 0.0) {
        let key: Key = (ch == " ") ? .space : .text(String(ch))
        press(after: delay, key, mods: mods)
    }

    /// Schedules an explicit `KeyEvent` press on the stage (`Play::press(ev)`).
    public mutating func press(_ event: KeyEvent, after delay: Double = 0.0) {
        scheduled.append((max(0.0, delay), .press(event)))
    }

    // Convenience Tx forwarders
    public mutating func commit() { tx.commit() }
    public mutating func instant() { tx.instant() }
    public mutating func focus(_ key: String) { tx.focus(key) }
    public mutating func blur() { tx.blur() }
    public mutating func wakeAfter(_ seconds: Double) { tx.wakeAfter(seconds) }
}

internal protocol AnyPlaygroundStaged: AnyObject {
    var isEmpty: Bool { get }
    func nextDue(after current: Double) -> Double?
}

internal protocol AnyPlaygroundResettableStaged: AnyObject {
    func setNow(_ now: Double)
}

/// Manages scheduled future steps and keys for an active `Story<X>` (`playground::stage::Staged`).
internal final class PlaygroundStaged<X>: AnyPlaygroundStaged, AnyPlaygroundResettableStaged {
    var now: Double = 0.0
    var needsImmediatePoll: Bool = false
    private var entries: [PlaygroundScheduledEntry<X>] = []
    private var nextSeq: UInt64 = 0

    func setNow(_ now: Double) {
        self.now = now
    }

    func absorb(from play: Play<X>, baseNow: Double? = nil) {
        if play.cleared {
            entries.removeAll()
        }
        let anchor = baseNow ?? now
        for item in play.scheduled {
            let seq = nextSeq
            nextSeq &+= 1
            let due = anchor + item.delay
            entries.append(PlaygroundScheduledEntry(dueAt: due, seq: seq, action: item.action))
        }
        entries.sort { a, b in
            if a.dueAt != b.dueAt { return a.dueAt < b.dueAt }
            return a.seq < b.seq
        }
    }

    func reset(at startNow: Double = 0.0) {
        now = startNow
        needsImmediatePoll = false
        entries.removeAll()
    }

    var isEmpty: Bool { entries.isEmpty && !needsImmediatePoll }

    func nextDue(after current: Double) -> Double? {
        if needsImmediatePoll {
            return current
        }
        guard let first = entries.first else { return nil }
        let due = first.dueAt
        return due > current ? due : current
    }

    func popNextDue(at targetNow: Double) -> (dueAt: Double, action: PlaygroundScheduledAction<X>)? {
        guard let first = entries.first else { return nil }
        guard first.dueAt <= targetNow + PlaygroundConst.dueSlack else { return nil }
        entries.removeFirst()
        return (first.dueAt, first.action)
    }
}

// MARK: - Story Builder & Type Erasure (`crates/rune/src/playground/story.rs`)

internal final class PlaygroundStateBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Standalone or overlay Playground story parameterized by its own state `P` (`playground::Story<P>`).
public struct Story<P> {
    public var path: String
    public var makeState: () -> P
    public var renderView: (P, inout Cx<P>) -> El<P>
    internal var realStateType: Any.Type? = nil
    internal var realDeriveBox: ((Any) -> P?)? = nil
    public var stageLayout: PlaygroundStageLayout? = nil
    public var stageFrame: Vec2? = nil
    public var overlayBackdrop: ((P, inout Cx<P>) -> El<P>)? = nil
    public var pollHook: ((inout P, Double, inout Play<P>) -> Bool)? = nil
    public var triggers: [(key: Character, label: String, action: (inout P, inout Play<P>) -> Void)] = []
    public var variants: [(name: String, apply: (inout P, inout Tx) -> Void)] = []
    public var sideView: ((P, inout Cx<P>) -> El<P>)? = nil
    public var sideKeysHook: (view: (P, Bool, inout Cx<P>) -> El<P>, onKey: (inout P, KeyEvent, inout Tx) -> Bool)? = nil

    public init(
        path: String,
        _ makeState: @escaping () -> P,
        _ view: @escaping (P, inout Cx<P>) -> El<P>
    ) {
        self.path = path
        self.makeState = makeState
        self.renderView = view
    }

    /// Creates a story whose initial/replayed state is derived from the host app's state `R` (`Story::from_real`).
    public static func fromReal<R>(
        _ path: String,
        _ derive: @escaping (R) -> P,
        _ view: @escaping (P, inout Cx<P>) -> El<P>
    ) -> Story<P> {
        var s = Story(
            path: path,
            { fatalError("Story.fromReal requires app state of type \(R.self)") },
            view
        )
        s.realStateType = R.self
        s.realDeriveBox = { ($0 as? R).map(derive) }
        return s
    }

    /// Returns true if this story can be attached to an app whose state type is `appStateType`.
    public func isCompatible<AppState>(with appStateType: AppState.Type) -> Bool {
        realStateType == nil || realStateType == appStateType
    }

    /// Marks the story as an overlay drawn over a backdrop (`Story::overlay`).
    public func overlay(_ backdrop: @escaping (P, inout Cx<P>) -> El<P>) -> Story<P> {
        var copy = self
        copy.overlayBackdrop = backdrop
        return copy
    }

    /// Attaches a per-frame poll callback receiving `(state, now, play)` (`Story::poll`).
    public func poll(_ body: @escaping (inout P, Double, inout Play<P>) -> Bool) -> Story<P> {
        var copy = self
        copy.pollHook = body
        return copy
    }

    /// Attaches a per-frame poll callback receiving `(state, play)` (`Story::poll`).
    public func poll(_ body: @escaping (inout P, inout Play<P>) -> Bool) -> Story<P> {
        var copy = self
        copy.pollHook = { state, _, play in body(&state, &play) }
        return copy
    }

    /// Adds a key trigger executed inside the story's `Play` choreography (`Story::trigger`).
    public func trigger(
        _ key: Character,
        _ label: String,
        _ action: @escaping (inout P, inout Play<P>) -> Void
    ) -> Story<P> {
        var copy = self
        copy.triggers.append((Character(key.lowercased()), label, action))
        return copy
    }

    /// Adds a `Tx`-only trigger without choreography (`Story::trigger_tx`).
    public func triggerTx(
        _ key: Character,
        _ label: String,
        _ action: @escaping (inout P, inout Tx) -> Void
    ) -> Story<P> {
        trigger(key, label) { state, play in
            action(&state, &play.tx)
        }
    }

    /// Attaches a custom inspector/side view rendered below the story title (`Story::side`).
    public func side(_ view: @escaping (P, inout Cx<P>) -> El<P>) -> Story<P> {
        var copy = self
        copy.sideView = view
        return copy
    }

    /// Attaches a keyboard-controlled side view (`Story::side_keys`).
    public func sideKeys(
        _ onKey: @escaping (inout P, KeyEvent, inout Tx) -> Bool,
        _ view: @escaping (P, Bool, inout Cx<P>) -> El<P>
    ) -> Story<P> {
        var copy = self
        copy.sideKeysHook = (view, onKey)
        return copy
    }

    /// Configures the stage layout and optional fixed frame size (`Story::stage`).
    public func stage(_ layout: PlaygroundStageLayout, _ frame: Vec2? = nil) -> Story<P> {
        var copy = self
        copy.stageLayout = layout
        copy.stageFrame = frame
        return copy
    }

    /// Registers a named variant mutating the story's initial state (`Story::variant`).
    public func variant(_ name: String, _ apply: @escaping (inout P, inout Tx) -> Void) -> Story<P> {
        var copy = self
        copy.variants.append((name, apply))
        return copy
    }
}

/// Type-erased runtime bridge for any `Story<P>` stored inside `PlaygroundHost<AppState>`.
internal protocol AnyPlaygroundOwnStory<AppState>: AnyObject {
    associatedtype AppState
    var path: String { get }
    var stageLayout: PlaygroundStageLayout? { get }
    var stageFrame: Vec2? { get }
    var isOverlay: Bool { get }
    var hasPollHook: Bool { get }
    var hasSideKeys: Bool { get }
    var triggerDescriptors: [(key: Character, label: String)] { get }
    var variantNames: [String] { get }
    func makeInitialBox(fromReal appState: Any) -> AnyObject
    func applyVariant(index: Int, box: AnyObject, tx: inout Tx) -> Bool
    func renderView(
        box: AnyObject,
        isValid: @escaping () -> Bool,
        cx: inout Cx<AppState>
    ) -> El<AppState>
    func renderSide(
        box: AnyObject,
        active: Bool,
        isValid: @escaping () -> Bool,
        cx: inout Cx<AppState>
    ) -> El<AppState>?
    func dispatchSideKey(_ event: KeyEvent, box: AnyObject, tx: inout Tx) -> Bool
    func runTrigger(key: Character, box: AnyObject, staged: AnyObject?, tx: inout Tx) -> (handled: Bool, pressedKeys: [KeyEvent])
    func runPollAndDueSteps(
        box: AnyObject,
        staged: AnyObject?,
        now: Double,
        tx: inout Tx
    ) -> (changed: Bool, pressedKeys: [KeyEvent], wakeAfter: Double?)
    func makeStaged() -> AnyObject
    func stopStaged(_ staged: AnyObject?)
    func withErasedState(box: AnyObject, tx: inout Tx, _ body: (inout Any, inout Tx) -> Void) -> Bool
}

internal final class TypedPlaygroundOwnStory<P, AppState>: AnyPlaygroundOwnStory {
    let story: Story<P>

    init(_ story: Story<P>) {
        self.story = story
    }

    var path: String { story.path }
    var stageLayout: PlaygroundStageLayout? { story.stageLayout }
    var stageFrame: Vec2? { story.stageFrame }
    var isOverlay: Bool { story.overlayBackdrop != nil }
    var hasPollHook: Bool { story.pollHook != nil }
    var hasSideKeys: Bool { story.sideKeysHook != nil }
    var triggerDescriptors: [(key: Character, label: String)] {
        story.triggers.map { ($0.key, $0.label) }
    }
    var variantNames: [String] { story.variants.map(\.name) }

    func makeInitialBox(fromReal appState: Any) -> AnyObject {
        if let derive = story.realDeriveBox, let derived = derive(appState) {
            return PlaygroundStateBox(derived)
        }
        return PlaygroundStateBox(story.makeState())
    }

    func makeStaged() -> AnyObject {
        let sched = PlaygroundStaged<P>()
        sched.needsImmediatePoll = (story.pollHook != nil)
        return sched
    }

    func stopStaged(_ staged: AnyObject?) {
        (staged as? PlaygroundStaged<P>)?.reset()
    }

    func applyVariant(index: Int, box: AnyObject, tx: inout Tx) -> Bool {
        guard let typed = box as? PlaygroundStateBox<P>,
              story.variants.indices.contains(index) else {
            return false
        }
        story.variants[index].apply(&typed.value, &tx)
        return true
    }

    func renderView(
        box: AnyObject,
        isValid: @escaping () -> Bool,
        cx: inout Cx<AppState>
    ) -> El<AppState> {
        guard let typed = box as? PlaygroundStateBox<P> else {
            return el()
        }
        var childCx: Cx<P> = cx.retype()
        childCx.clearChrome()
        let content: El<P>
        if let backdrop = story.overlayBackdrop {
            let bg = backdrop(typed.value, &childCx)
            let fg = story.renderView(typed.value, &childCx)
            content = El<P>(direction: .column)
                .wFull()
                .hFull()
                .child(bg)
                .child(
                    El<P>(direction: .column)
                        .pin(top: 0, right: 0, bottom: 0, left: 0)
                        .center()
                        .child(fg)
                )
        } else {
            content = story.renderView(typed.value, &childCx)
        }
        cx.absorb(childCx)
        return content.liftHandlers(
            isValid: isValid,
            get: { typed.value },
            set: { typed.value = $0 }
        )
    }

    func renderSide(
        box: AnyObject,
        active: Bool,
        isValid: @escaping () -> Bool,
        cx: inout Cx<AppState>
    ) -> El<AppState>? {
        guard let typed = box as? PlaygroundStateBox<P> else { return nil }
        var childCx: Cx<P> = cx.retype()
        let raw: El<P>?
        if let sideKeys = story.sideKeysHook {
            raw = sideKeys.view(typed.value, active, &childCx)
        } else if let sideView = story.sideView {
            raw = sideView(typed.value, &childCx)
        } else {
            raw = nil
        }
        guard let elP = raw else { return nil }
        cx.absorb(childCx)
        return elP.liftHandlers(
            isValid: isValid,
            get: { typed.value },
            set: { typed.value = $0 }
        )
    }

    func dispatchSideKey(_ event: KeyEvent, box: AnyObject, tx: inout Tx) -> Bool {
        guard let typed = box as? PlaygroundStateBox<P>,
              let sideKeys = story.sideKeysHook else {
            return false
        }
        return sideKeys.onKey(&typed.value, event, &tx)
    }

    func runTrigger(
        key: Character,
        box: AnyObject,
        staged: AnyObject?,
        tx: inout Tx
    ) -> (handled: Bool, pressedKeys: [KeyEvent]) {
        guard let typed = box as? PlaygroundStateBox<P> else { return (false, []) }
        let lower = Character(key.lowercased())
        guard let match = story.triggers.first(where: { Character($0.key.lowercased()) == lower }) else {
            return (false, [])
        }
        let sched = staged as? PlaygroundStaged<P>
        let baseNow = sched?.now ?? 0.0
        var play = Play<P>(tx: tx, now: baseNow)
        match.action(&typed.value, &play)
        tx = play.tx
        if let sched {
            sched.absorb(from: play, baseNow: baseNow)
        }
        let immediate = runImmediateZeroSteps(box: typed, staged: sched, tx: &tx)
        return (true, immediate)
    }

    func runPollAndDueSteps(
        box: AnyObject,
        staged: AnyObject?,
        now: Double,
        tx: inout Tx
    ) -> (changed: Bool, pressedKeys: [KeyEvent], wakeAfter: Double?) {
        guard let typed = box as? PlaygroundStateBox<P> else {
            return (false, [], nil)
        }
        var changed = false
        var pressed: [KeyEvent] = []
        let sched = staged as? PlaygroundStaged<P>
        sched?.now = now
        sched?.needsImmediatePoll = false

        if let pollFn = story.pollHook {
            var play = Play<P>(tx: tx, now: now)
            let res = pollFn(&typed.value, now, &play)
            tx = play.tx
            if res || tx.isForceCommitRequested { changed = true }
            sched?.absorb(from: play, baseNow: now)
        }

        if let sched {
            var stepsRun = 0
            while stepsRun < PlaygroundConst.maxStepsPerFrame,
                  let due = sched.popNextDue(at: now) {
                stepsRun += 1
                changed = true
                switch due.action {
                case .step(let fn):
                    var play = Play<P>(tx: tx, now: due.dueAt)
                    fn(&typed.value, &play)
                    tx = play.tx
                    sched.absorb(from: play, baseNow: due.dueAt)
                case .press(let ev):
                    pressed.append(ev)
                }
            }
            if let next = sched.nextDue(after: now) {
                return (changed, pressed, max(0.0, next - now))
            }
        }
        return (changed, pressed, nil)
    }

    private func runImmediateZeroSteps(
        box typed: PlaygroundStateBox<P>,
        staged: PlaygroundStaged<P>?,
        tx: inout Tx
    ) -> [KeyEvent] {
        guard let sched = staged else { return [] }
        var pressed: [KeyEvent] = []
        var count = 0
        while count < PlaygroundConst.maxStepsPerFrame,
              let due = sched.popNextDue(at: sched.now) {
            count += 1
            switch due.action {
            case .step(let fn):
                var play = Play<P>(tx: tx, now: due.dueAt)
                fn(&typed.value, &play)
                tx = play.tx
                sched.absorb(from: play, baseNow: due.dueAt)
            case .press(let ev):
                pressed.append(ev)
            }
        }
        return pressed
    }

    func withErasedState(box: AnyObject, tx: inout Tx, _ body: (inout Any, inout Tx) -> Void) -> Bool {
        guard let typed = box as? PlaygroundStateBox<P> else { return false }
        var erased: Any = typed.value
        body(&erased, &tx)
        if let updated = erased as? P {
            typed.value = updated
        }
        return true
    }
}

// MARK: - Navigation, Requests, Region, Slugs (`playground.rs`, `nav.rs`, `region.rs`, `open.rs`)

public enum PlaygroundRegion: Sendable, Equatable {
    case list
    case stage
    case side
}

internal enum PlaygroundNav: Equatable {
    case listStep(Int)
    case listJump(Int) // < 0 first, > 0 last
    case sideStep(Int)
    case toggleFold(group: String)
    case foldOrParent
    case unfoldOrChild
    case intoFilter
    case intoSide
    case intoStage
    case outOfSide
    case variant(Int)
    case trigger(Character)
    case replay
}

internal enum PlaygroundMoved {
    case give(PlaygroundRegion, seen: String?)
    case hold(PlaygroundRegion)
    case resume(PlaygroundRegion, back: String?)
    case focus(focus: String?, region: PlaygroundRegion?)
    case slot(Bool)
    case closed
}

internal struct PlaygroundKeyboard {
    var region: PlaygroundRegion = .list
    var slotFocused: Bool = false
    var seen: String? = nil

    func saw(_ focus: String?) -> Bool {
        seen == focus
    }

    @discardableResult
    mutating func step(_ moved: PlaygroundMoved) -> Bool {
        let beforeRegion = region
        let beforeSlot = slotFocused
        switch moved {
        case .give(let r, let s):
            region = r
            seen = s
        case .hold(let r):
            region = r
        case .resume(let r, let back):
            region = r
            if let back {
                seen = back
            }
        case .focus(let focus, let r):
            if seen != focus {
                seen = focus
                if let r {
                    region = r
                }
            }
        case .slot(let active):
            slotFocused = active
        case .closed:
            region = .list
        }
        return (region != beforeRegion) || (slotFocused != beforeSlot)
    }
}

public enum PlaygroundRequest: Equatable {
    case open
    case openAt(String, variant: String?)
    case close
    case toggle
    case select(Int)
    case replay
    case keep
    case variant(Int)
    case trigger(Character)
    case dark(Bool)
    case size(Int)
    case reduceMotion(Bool)
    case header(String)
    case fold(String, Bool?)

    public var swapsStage: Bool {
        switch self {
        case .open, .openAt, .close, .toggle, .select, .replay, .variant:
            return true
        case .keep, .trigger, .dark, .size, .reduceMotion, .header, .fold:
            return false
        }
    }
}

internal final class PlaygroundChromeActionBox {
    let apply: () -> Void
    init(_ apply: @escaping () -> Void) { self.apply = apply }
}

public enum PlaygroundSlug {
    /// Lowercase ASCII/Unicode slug collapsing non-alphanumeric runs to single `-` (`playground/open.rs`).
    public static func slug(for raw: String) -> String {
        var out = ""
        var inDash = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                for lc in String(scalar).lowercased() {
                    out.append(lc)
                }
                inDash = false
            } else if !inDash && !out.isEmpty {
                out.append("-")
                inDash = true
            }
        }
        if out.hasSuffix("-") {
            out.removeLast()
        }
        return out
    }
}

public enum PlaygroundEnv {
    public static func hiddenByEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["RUNE_PLAYGROUND"] == "0"
    }

    public static func offeredByEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !hiddenByEnv(env)
    }
}

// MARK: - Story Side Attachments (`playground::Side`)

internal enum PlaygroundSideKind<State> {
    case stage((State, inout Cx<State>) -> El<State>)
    case real((State, State, inout Cx<State>) -> El<State>)
    case keys(
        onKey: (inout State, KeyEvent, inout Tx) -> Bool,
        view: (State, Bool, inout Cx<State>) -> El<State>
    )
}

internal struct PlaygroundHostLiveSpec<State> {
    var orderedPages: [PlaygroundPageItem<State>] = []
    var sceneTriggers: [(story: String, key: Character, label: String, action: (inout State, inout Play<State>) -> Void)] = []
    var sceneSides: [(story: String, side: PlaygroundSideKind<State>)] = []
    var sceneStages: [(story: String, layout: PlaygroundStageLayout, frame: Vec2?)] = []
    var sceneVariants: [(story: String, name: String, apply: (inout State, inout Tx) -> Void)] = []
    var pollStageHook: ((inout State, Double, inout Play<State>) -> Bool)? = nil
    var loadFoldsHook: (() -> [String])? = nil
    var saveFoldsHook: (([String]) -> Void)? = nil
    var loadWidthsHook: (() -> (Float, Float)?)? = nil
    var saveWidthsHook: ((Float, Float) -> Void)? = nil
    var shortcutMenuEnabled: Bool = true
    var hasCustomSizes: Bool = false
    var keepsScene: Bool = false
}
