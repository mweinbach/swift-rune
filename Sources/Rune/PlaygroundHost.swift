import Foundation
import RuneMotion

// MARK: - Playground Runner, Knobs, Viewport Presets & Scene Matrix

public struct ViewportPreset: Sendable, Equatable {
    public var name: String
    public var size: Vec2

    public init(name: String, size: Vec2) {
        self.name = name
        self.size = size
    }

    public static let compact = ViewportPreset(name: "Compact", size: Vec2(360, 240))
    public static let medium = ViewportPreset(name: "Medium", size: Vec2(640, 480))
    public static let wide = ViewportPreset(name: "Wide", size: Vec2(960, 640))
}

public enum PlaygroundKnob: Sendable, Equatable {
    case toggle(id: String, label: String, defaultValue: Bool)
    case slider(id: String, label: String, min: Float, max: Float, step: Float, defaultValue: Float)
    case choice(id: String, label: String, options: [String], defaultIndex: Int)
    case text(id: String, label: String, defaultValue: String)

    public var id: String {
        switch self {
        case .toggle(let id, _, _),
             .slider(let id, _, _, _, _, _),
             .choice(let id, _, _, _),
             .text(let id, _, _):
            return id
        }
    }

    public var label: String {
        switch self {
        case .toggle(_, let label, _),
             .slider(_, let label, _, _, _, _),
             .choice(_, let label, _, _),
             .text(_, let label, _):
            return label
        }
    }
}

public struct PlaygroundControlValues: Sendable, Equatable {
    public var bools: [String: Bool] = [:]
    public var floats: [String: Float] = [:]
    public var choices: [String: Int] = [:]
    public var texts: [String: String] = [:]

    public init() {}

    public func bool(_ id: String, default fallback: Bool = false) -> Bool {
        bools[id] ?? fallback
    }

    public func float(_ id: String, default fallback: Float = 0) -> Float {
        floats[id] ?? fallback
    }

    public func choiceIndex(_ id: String, default fallback: Int = 0) -> Int {
        choices[id] ?? fallback
    }

    public func string(_ id: String, default fallback: String = "") -> String {
        texts[id] ?? fallback
    }
}

public struct PlaygroundTrigger<State> {
    public var key: Character?
    public var label: String
    public var action: (inout State, inout Tx) -> Void

    public init(key: Character? = nil, label: String, action: @escaping (inout State, inout Tx) -> Void) {
        self.key = key
        self.label = label
        self.action = action
    }
}

public enum PlaygroundLookupError: Error, Equatable, Sendable {
    case unknownStory(name: String, available: [String])
    case unknownVariant(name: String, story: String, available: [String])
}

public struct PlaygroundVariant<State> {
    public var name: String
    public var apply: (inout State) -> Void

    public init(name: String, apply: @escaping (inout State) -> Void) {
        self.name = name
        self.apply = apply
    }
}

public struct PlaygroundStageConfig: Sendable, Equatable {
    public var size: Vec2?
    public var centered: Bool

    public init(size: Vec2? = nil, centered: Bool = true) {
        self.size = size
        self.centered = centered
    }
}

public struct PlaygroundStory<State> {
    public var path: String
    public var slug: String
    public var groupPath: [String]
    public var name: String
    public var triggers: [PlaygroundTrigger<State>]
    public var variants: [PlaygroundVariant<State>]
    public var sideView: ((State, inout Cx<State>) -> El<State>)?
    public var stageConfig: PlaygroundStageConfig
    public var isScene: Bool
    public var makeState: (() -> State)?
    public var view: (State, PlaygroundControlValues, inout Cx<State>) -> El<State>

    public init(
        path: String,
        triggers: [PlaygroundTrigger<State>] = [],
        variants: [PlaygroundVariant<State>] = [],
        sideView: ((State, inout Cx<State>) -> El<State>)? = nil,
        stageConfig: PlaygroundStageConfig = PlaygroundStageConfig(),
        isScene: Bool = false,
        makeState: (() -> State)? = nil,
        view: @escaping (State, PlaygroundControlValues, inout Cx<State>) -> El<State>
    ) {
        self.path = path
        self.slug = Self.slug(for: path)
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 1 {
            self.groupPath = Array(parts.dropLast())
            self.name = parts.last!
        } else {
            self.groupPath = [isScene ? "Scenes" : "Pages"]
            self.name = path
        }
        self.triggers = triggers
        self.variants = variants
        self.sideView = sideView
        self.stageConfig = stageConfig
        self.isScene = isScene
        self.makeState = makeState
        self.view = view
    }

    public static func slug(for path: String) -> String {
        path.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.last == "-" { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct SceneMatrixCell: Sendable, Equatable {
    public let storyPath: String
    public let storySlug: String
    public let presetName: String
    public let viewport: Vec2
    public let rootWidth: Float
    public let rootHeight: Float

    public init(
        storyPath: String,
        storySlug: String,
        presetName: String,
        viewport: Vec2,
        rootWidth: Float,
        rootHeight: Float
    ) {
        self.storyPath = storyPath
        self.storySlug = storySlug
        self.presetName = presetName
        self.viewport = viewport
        self.rootWidth = rootWidth
        self.rootHeight = rootHeight
    }
}

/// Built-in story/component `Playground` runner (`rune::playground::Playground`).
public final class PlaygroundHost<State> {
    public private(set) var stories: [PlaygroundStory<State>] = []
    public private(set) var knobs: [PlaygroundKnob] = []
    public private(set) var presets: [ViewportPreset] = [.compact, .medium, .wide]
    public var controls = PlaygroundControlValues()

    public var isOpen: Bool = false
    public var filterQuery: String = ""
    public var selectedStoryPath: String?
    public var selectedVariantIndex: Int?
    public var selectedPresetIndex: Int = 1
    public var foldedGroups: Set<String> = []
    public var groupOrder: [String] = []
    public var startFolded: Bool = false
    public var showBar: Bool = true
    public var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    public var shortcutChord: Chord? = {
        #if os(macOS)
        return Chord(parsing: "shift+cmd+d")
        #else
        return Chord(parsing: "ctrl+shift+d")
        #endif
    }()
    public var scenesFilter: ((String) -> Bool)? = nil
    public var freshTransform: ((State) -> State)? = nil
    public var keepTransform: ((State, inout State) -> Void)? = nil
    public var typingPredicate: ((State) -> Bool)? = nil
    public var darkPredicate: ((State) -> Bool)? = nil

    public private(set) var replayCount: Int = 0
    public private(set) var triggersFired: [(story: String, key: Character)] = []
    private var pendingTriggers: [(story: String, trigger: PlaygroundTrigger<State>)] = []
    private var pendingVariants: [(story: String, variant: PlaygroundVariant<State>)] = []
    private var pendingSides: [(story: String, view: (State, inout Cx<State>) -> El<State>)] = []
    private var pendingStages: [(story: String, config: PlaygroundStageConfig)] = []

    public init() {}

    @discardableResult
    public func story(_ story: PlaygroundStory<State>) -> Self {
        var resolved = story
        applyPendingAttachments(to: &resolved)
        stories.append(resolved)
        if selectedStoryPath == nil {
            selectedStoryPath = resolved.path
        }
        return self
    }

    @discardableResult
    public func page(
        _ path: String,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) -> Self {
        story(PlaygroundStory(path: path) { state, _, cx in
            view(state, &cx)
        })
    }

    @discardableResult
    public func trigger(
        _ scene: String,
        key: Character,
        label: String,
        action: @escaping (inout State, inout Tx) -> Void
    ) -> Self {
        let trig = PlaygroundTrigger<State>(key: Character(key.lowercased()), label: label, action: action)
        if let idx = storyIndex(matching: scene) {
            stories[idx].triggers.append(trig)
        } else {
            pendingTriggers.append((scene, trig))
        }
        return self
    }

    @discardableResult
    public func variant(
        _ scene: String,
        name: String,
        apply: @escaping (inout State) -> Void
    ) -> Self {
        let variant = PlaygroundVariant<State>(name: name, apply: apply)
        if let idx = storyIndex(matching: scene) {
            stories[idx].variants.append(variant)
        } else {
            pendingVariants.append((scene, variant))
        }
        return self
    }

    @discardableResult
    public func side(
        _ scene: String,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) -> Self {
        if let idx = storyIndex(matching: scene) {
            stories[idx].sideView = view
        } else {
            pendingSides.append((scene, view))
        }
        return self
    }

    @discardableResult
    public func stage(
        _ scene: String,
        config: PlaygroundStageConfig
    ) -> Self {
        if let idx = storyIndex(matching: scene) {
            stories[idx].stageConfig = config
        } else {
            pendingStages.append((scene, config))
        }
        return self
    }

    @discardableResult
    public func bar(_ visible: Bool) -> Self {
        self.showBar = visible
        return self
    }

    @discardableResult
    public func enabled(_ value: Bool) -> Self {
        self.isEnabled = value
        return self
    }

    @discardableResult
    public func shortcut(_ chord: Chord?) -> Self {
        self.shortcutChord = chord
        return self
    }

    @discardableResult
    public func scenes(_ filter: @escaping (String) -> Bool) -> Self {
        self.scenesFilter = filter
        return self
    }

    @discardableResult
    public func fresh(_ transform: @escaping (State) -> State) -> Self {
        self.freshTransform = transform
        return self
    }

    @discardableResult
    public func keep(_ transform: @escaping (State, inout State) -> Void) -> Self {
        self.keepTransform = transform
        return self
    }

    @discardableResult
    public func typing(_ predicate: @escaping (State) -> Bool) -> Self {
        self.typingPredicate = predicate
        return self
    }

    @discardableResult
    public func dark(_ predicate: @escaping (State) -> Bool) -> Self {
        self.darkPredicate = predicate
        return self
    }

    @discardableResult
    public func groupOrder(_ order: [String]) -> Self {
        self.groupOrder = order
        return self
    }

    @discardableResult
    public func startFolded(_ folded: Bool = true) -> Self {
        self.startFolded = folded
        return self
    }

    @discardableResult
    public func knob(_ knob: PlaygroundKnob) -> Self {
        knobs.append(knob)
        switch knob {
        case .toggle(let id, _, let def):
            if controls.bools[id] == nil { controls.bools[id] = def }
        case .slider(let id, _, _, _, _, let def):
            if controls.floats[id] == nil { controls.floats[id] = def }
        case .choice(let id, _, _, let def):
            if controls.choices[id] == nil { controls.choices[id] = def }
        case .text(let id, _, let def):
            if controls.texts[id] == nil { controls.texts[id] = def }
        }
        return self
    }

    @discardableResult
    public func viewportPresets(_ newPresets: [ViewportPreset]) -> Self {
        if !newPresets.isEmpty {
            self.presets = newPresets
            self.selectedPresetIndex = min(selectedPresetIndex, newPresets.count - 1)
        }
        return self
    }

    /// Binds `AppSpec.scenes` into the story list ahead of pages, honoring `scenesFilter` (`playground.rs`).
    public func bindScenes(
        _ scenes: [String: (inout State, inout Tx) -> Void],
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        var addedScenes: [PlaygroundStory<State>] = []
        for name in scenes.keys.sorted() {
            if let filter = scenesFilter, !filter(name) { continue }
            if stories.contains(where: { $0.path == name }) { continue }
            let applyScene = scenes[name]!
            var story = PlaygroundStory<State>(
                path: name,
                isScene: true,
                view: { st, _, cx in
                    var mutable = st
                    var tx = Tx()
                    applyScene(&mutable, &tx)
                    return view(mutable, &cx)
                }
            )
            applyPendingAttachments(to: &story)
            addedScenes.append(story)
        }
        if !addedScenes.isEmpty {
            stories.insert(contentsOf: addedScenes, at: 0)
            if selectedStoryPath == nil {
                selectedStoryPath = stories.first?.path
            }
        }
    }

    private func applyPendingAttachments(to story: inout PlaygroundStory<State>) {
        story.triggers.append(contentsOf: pendingTriggers.filter { storyMatches($0.story, story) }.map(\.trigger))
        story.variants.append(contentsOf: pendingVariants.filter { storyMatches($0.story, story) }.map(\.variant))
        if let lastSide = pendingSides.last(where: { storyMatches($0.story, story) }) {
            story.sideView = lastSide.view
        }
        if let lastStage = pendingStages.last(where: { storyMatches($0.story, story) }) {
            story.stageConfig = lastStage.config
        }
    }

    private func storyMatches(_ needle: String, _ story: PlaygroundStory<State>) -> Bool {
        story.path == needle
            || story.name == needle
            || story.path.caseInsensitiveCompare(needle) == .orderedSame
            || story.name.caseInsensitiveCompare(needle) == .orderedSame
            || story.slug == needle
    }

    /// Exact path/name -> case-insensitive path/name -> slug match (`playground/open.rs`).
    public func storyIndex(matching query: String) -> Int? {
        if let i = stories.firstIndex(where: { $0.path == query || $0.name == query }) {
            return i
        }
        if let i = stories.firstIndex(where: {
            $0.path.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return i
        }
        let targetSlug = PlaygroundStory<State>.slug(for: query)
        return stories.firstIndex(where: { $0.slug == query || $0.slug == targetSlug })
    }

    public func findStory(named query: String) -> PlaygroundStory<State>? {
        storyIndex(matching: query).map { stories[$0] }
    }

    public func open(storyPath: String? = nil) {
        isOpen = true
        if let p = storyPath, let found = findStory(named: p) {
            selectedStoryPath = found.path
            selectedVariantIndex = nil
        } else if selectedStoryPath == nil {
            selectedStoryPath = stories.first?.path
        }
    }

    public func openAt(story: String?, variant: String? = nil) throws {
        guard isEnabled || !stories.isEmpty else {
            if let story {
                throw PlaygroundLookupError.unknownStory(name: story, available: [])
            }
            return
        }
        let targetIndex: Int?
        if let story {
            guard let idx = storyIndex(matching: story) else {
                throw PlaygroundLookupError.unknownStory(name: story, available: stories.map(\.path))
            }
            targetIndex = idx
        } else if let selected = selectedStoryPath {
            targetIndex = storyIndex(matching: selected)
        } else {
            targetIndex = stories.isEmpty ? nil : 0
        }

        if let idx = targetIndex {
            selectedStoryPath = stories[idx].path
            if let variant {
                let storyObj = stories[idx]
                if let oneBased = Int(variant), (1...storyObj.variants.count).contains(oneBased) {
                    selectedVariantIndex = oneBased - 1
                } else if let vIdx = storyObj.variants.firstIndex(where: { $0.name.caseInsensitiveCompare(variant) == .orderedSame }) {
                    selectedVariantIndex = vIdx
                } else {
                    throw PlaygroundLookupError.unknownVariant(
                        name: variant,
                        story: storyObj.path,
                        available: storyObj.variants.map(\.name)
                    )
                }
            } else {
                selectedVariantIndex = nil
            }
        }
        isOpen = true
    }

    public var currentVariant: PlaygroundVariant<State>? {
        guard let story = currentStory, let idx = selectedVariantIndex, idx >= 0, idx < story.variants.count else {
            return nil
        }
        return story.variants[idx]
    }

    public func replay(on state: inout State, tx: inout Tx) {
        guard isOpen else { return }
        replayCount += 1
        if let story = currentStory {
            for trig in story.triggers where trig.key.map({ Character($0.lowercased()) }) == "r" {
                trig.action(&state, &tx)
                triggersFired.append((story.path, "r"))
            }
        }
    }

    @discardableResult
    public func fireTrigger(_ key: Character, on state: inout State, tx: inout Tx) -> Bool {
        guard isOpen, let story = currentStory else { return false }
        let lower = Character(key.lowercased())
        if lower == "r" {
            replay(on: &state, tx: &tx)
            return true
        }
        guard let trig = story.triggers.first(where: { $0.key.map({ Character($0.lowercased()) }) == lower }) else {
            return false
        }
        trig.action(&state, &tx)
        triggersFired.append((story.path, lower))
        return true
    }

    public func close() {
        isOpen = false
    }

    public func toggle() {
        if isOpen { close() } else { open() }
    }

    public func toggleGroup(_ group: String) {
        if foldedGroups.contains(group) {
            foldedGroups.remove(group)
        } else {
            foldedGroups.insert(group)
        }
    }

    public func filteredStories() -> [PlaygroundStory<State>] {
        let words = filterQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return stories }
        return stories.filter { story in
            let hay = story.path.lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    public var currentStory: PlaygroundStory<State>? {
        guard let path = selectedStoryPath else { return stories.first }
        return stories.first(where: { $0.path == path }) ?? stories.first
    }

    public var currentPreset: ViewportPreset {
        guard !presets.isEmpty else { return .medium }
        let idx = min(max(0, selectedPresetIndex), presets.count - 1)
        return presets[idx]
    }

    /// Evaluates every story across every viewport preset and returns layout metrics for matrix verification.
    public func evaluateSceneMatrix(initialState: () -> State) -> [SceneMatrixCell] {
        var cells: [SceneMatrixCell] = []
        for story in stories {
            let st = story.makeState?() ?? initialState()
            for preset in presets {
                let rt = Runtime<State>(
                    state: st,
                    viewport: preset.size,
                    view: { s, cx in
                        story.view(s, self.controls, &cx)
                    }
                )
                _ = rt.frame(at: 0)
                let rootRect = rt.elements().first?.rect ?? [0, 0, 0, 0]
                let rw = rootRect.count >= 4 ? rootRect[2] : 0
                let rh = rootRect.count >= 4 ? rootRect[3] : 0
                cells.append(SceneMatrixCell(
                    storyPath: story.path,
                    storySlug: story.slug,
                    presetName: preset.name,
                    viewport: preset.size,
                    rootWidth: rw,
                    rootHeight: rh
                ))
            }
        }
        return cells
    }
}
