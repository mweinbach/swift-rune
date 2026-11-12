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

public struct PlaygroundStory<State> {
    public var path: String
    public var slug: String
    public var groupPath: [String]
    public var name: String
    public var triggers: [PlaygroundTrigger<State>]
    public var makeState: (() -> State)?
    public var view: (State, PlaygroundControlValues, inout Cx<State>) -> El<State>

    public init(
        path: String,
        triggers: [PlaygroundTrigger<State>] = [],
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
            self.groupPath = ["Pages"]
            self.name = path
        }
        self.triggers = triggers
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
    public var selectedPresetIndex: Int = 1
    public var foldedGroups: Set<String> = []
    public var groupOrder: [String] = []

    public init() {}

    @discardableResult
    public func story(_ story: PlaygroundStory<State>) -> Self {
        stories.append(story)
        if selectedStoryPath == nil {
            selectedStoryPath = story.path
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

    public func open(storyPath: String? = nil) {
        isOpen = true
        if let p = storyPath, stories.contains(where: { $0.path == p || $0.slug == p }) {
            selectedStoryPath = stories.first(where: { $0.path == p || $0.slug == p })?.path
        } else if selectedStoryPath == nil {
            selectedStoryPath = stories.first?.path
        }
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
