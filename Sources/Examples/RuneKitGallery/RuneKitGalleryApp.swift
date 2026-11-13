import Foundation
import OpenCodeTheme
import Rune
import RuneKit

/// Shared mutable state for the 131-story RuneKit gallery (`examples/kit-gallery`).
public struct GalleryState: Sendable {
    public var story: String = "index"
    public var on: Set<String> = []
    public var pick: [String: String] = [:]
    public var open: String? = nil
    public var edits: [TextEdit] = Array(repeating: TextEdit(), count: 8)
    public var comboOpen: Bool = false
    public var comboActive: Int = 0
    public var hoverCopy: Bool = false
    public var fileExpanded: Set<String> = ["src", "src/util"]
    public var fileSelected: String? = "src/util/format.ts"
    public var neutral: Bool = false
    public var palette: Bool = false
    public var paletteBlack: Bool = false
    public var paletteWarm: Bool = false
    public var reduced: Bool = false

    public init(
        story: String = "index",
        neutral: Bool = false,
        palette: Bool = false,
        paletteBlack: Bool = false,
        paletteWarm: Bool = false,
        reduced: Bool = false
    ) {
        self.story = story
        self.neutral = neutral
        self.palette = palette
        self.paletteBlack = paletteBlack
        self.paletteWarm = paletteWarm
        self.reduced = reduced
    }

    public static func initFromArgs(_ args: [String] = CommandLine.arguments) -> GalleryState {
        var state = GalleryState()
        for i in args.indices {
            let arg = args[i]
            if arg == "--kit", i + 1 < args.count {
                let kind = args[i + 1].lowercased()
                if kind == "neutral" {
                    state.neutral = true
                } else if kind == "palette" {
                    state.palette = true
                    if i + 2 < args.count {
                        let variant = args[i + 2].lowercased()
                        if variant == "black" { state.paletteBlack = true }
                        if variant == "warm" { state.paletteWarm = true }
                    }
                }
            } else if arg == "--reduced-motion" {
                state.reduced = true
            }
        }
        return state
    }

    public func isOn(_ key: String) -> Bool { on.contains(key) }
    public func `is`(_ key: String) -> Bool { on.contains(key) }

    public mutating func flip(_ key: String) {
        if on.contains(key) { on.remove(key) } else { on.insert(key) }
    }

    public func picked(_ group: String, _ defaultValue: String) -> String {
        pick[group] ?? defaultValue
    }

    public func isOpen(_ key: String) -> Bool { open == key }

    public mutating func toggleOpen(_ key: String) {
        open = (open == key) ? nil : key
    }
}

public func resolveGalleryKit(_ s: GalleryState, dark: Bool) -> Kit {
    if s.palette {
        if dark {
            if s.paletteBlack {
                let seed = PaletteSeed(
                    bg: Color.hex("#000000")!,
                    fg: Color.hex("#ffffff")!,
                    accent: Color.hex("#ff2a2a")!
                )
                return Kit.fromPalette(seed, focus: .ink)
            }
            let seed = PaletteSeed(
                bg: Color.hex("#0a0a0a")!,
                fg: Color.hex("#ededed")!,
                accent: Color.hex("#e5484d")!
            )
            return Kit.fromPalette(seed)
        } else {
            if s.paletteWarm {
                let seed = PaletteSeed(
                    bg: Color.hex("#e8e4dc")!,
                    fg: Color.hex("#000000")!,
                    accent: Color.hex("#d81414")!
                )
                return Kit.fromPalette(seed, focus: .ink)
            }
            let seed = PaletteSeed(
                bg: Color.hex("#ffffff")!,
                fg: Color.hex("#171717")!,
                accent: Color.hex("#e5484d")!
            )
            return Kit.fromPalette(seed)
        }
    }
    if s.neutral {
        return Kit.neutral(dark: dark)
    }
    return OpenCodeTheme.kit(dark: dark)
}

public typealias GalleryStoryRenderer = @Sendable (GalleryState, Kit, inout [El<GalleryState>]) -> El<GalleryState>

/// Exact 131 Storybook story IDs from upstream `examples/kit-gallery/src/stories.rs`.
public let galleryStories: [(id: String, render: GalleryStoryRenderer)] = [
    ("rune-combobox--searchable", comboboxSearchable),
    ("rune-combobox--animated-filter", comboboxAnimatedFilter),
    ("ui-dialog--basic", dialogBasic),
    ("motion-focus-modal", motionFocusModal),
    ("motion-stagger-list", motionStaggerList),
    ("ui-button--playground", buttonPlayground),
    ("ui-button--variants", buttonVariants),
    ("ui-button--sizes", buttonSizes),
    ("ui-button--icon", buttonIcon),
    ("ui-button--all-states", buttonAllStates),
    ("ui-icon-button--playground", iconButtonPlayground),
    ("ui-icon-button--variants", iconButtonVariants),
    ("ui-icon-button--sizes", iconButtonSizes),
    ("ui-icon-button--all-states", iconButtonAllStates),
    ("ui-switch--basic", switchBasic),
    ("ui-switch--appearances", switchAppearances),
    ("ui-switch--states", switchStates),
    ("ui-switch--hidden-label", switchHiddenLabel),
    ("rune-switch--web", switchWeb),
    ("ui-checkbox--basic", checkboxBasic),
    ("ui-checkbox--states", checkboxStates),
    ("ui-checkbox--custom-icon", checkboxCustomIcon),
    ("ui-checkbox--hidden-label", checkboxHiddenLabel),
    ("ui-radio--basic", radioBasic),
    ("ui-radio--controlled", radioControlled),
    ("ui-radio--states", radioStates),
    ("ui-text-input--playground", textInputPlayground),
    ("ui-text-input--with-copy-button", textInputCopy),
    ("ui-text-input--controlled", textInputControlled),
    ("ui-text-input--appearances", textInputAppearances),
    ("ui-text-input--with-field", textInputWithField),
    ("ui-text-input--states", textInputStates),
    ("ui-textarea--playground", textareaPlayground),
    ("ui-textarea--controlled", textareaControlled),
    ("ui-textarea--with-field", textareaWithField),
    ("ui-textarea--states", textareaStates),
    ("ui-field--text-input-example", fieldTextInput),
    ("ui-field--text-input-direct-child", fieldDirectChild),
    ("ui-field--textarea-example", fieldTextarea),
    ("ui-field--invalid", fieldInvalid),
    ("ui-select--playground", selectPlayground),
    ("ui-select--grouped", selectGrouped),
    ("ui-select--invalid", selectInvalid),
    ("ui-select--disabled", selectDisabled),
    ("ui-select--with-field", selectWithField),
    ("rune-select--states", selectStates),
    ("components-popover--basic", popoverBasic),
    ("components-popover--controlled", popoverControlled),
    ("ui-menu--basic", menuBasic),
    ("ui-menu--appearances", menuAppearances),
    ("ui-menu--rich", menuRich),
    ("ui-menu--with-checkbox", menuCheckbox),
    ("ui-menu--with-radio", menuRadio),
    ("ui-menu--with-submenu", menuSubmenu),
    ("ui-tooltip--simple", tooltipSimple),
    ("ui-tooltip--with-keybind", tooltipKeybind),
    ("ui-tooltip--path", tooltipPath),
    ("ui-tooltip--title-description", tooltipTitleDescription),
    ("components-hover-card--basic", hoverCardBasic),
    ("ui-toast--all-examples", toastAll),
    ("components-card--normal", cardNormal),
    ("components-card--error", cardError),
    ("components-card--warning", cardWarning),
    ("components-card--success", cardSuccess),
    ("components-card--info", cardInfo),
    ("components-list--basic", listBasic),
    ("components-list--grouped", listGrouped),
    ("components-list--empty", listEmpty),
    ("components-list--with-add", listWithAdd),
    ("components-list--divider", listDivider),
    ("components-list--active-icon", listActiveIcon),
    ("components-list--no-search", listNoSearch),
    ("ui-accordion--basic", accordionBasic),
    ("ui-accordion--multiple", accordionMultiple),
    ("ui-accordion--non-collapsible", accordionSingle),
    ("components-collapsible--basic", collapsibleBasic),
    ("components-collapsible--ghost", collapsibleGhost),
    ("ui-badge--basic", badgeBasic),
    ("ui-badge--appearances", badgeAppearances),
    ("ui-badge--subtle", badgeSubtle),
    ("ui-badge--high-contrast", badgeHighContrast),
    ("ui-badge--accent", badgeAccent),
    ("ui-keybind--playground", keybindPlayground),
    ("ui-keybind--variants", keybindVariants),
    ("ui-keybind--multiple-keys", keybindMultiple),
    ("ui-keybind--all-examples", keybindAll),
    ("components-spinner--basic", spinnerBasic),
    ("components-spinner--sizes", spinnerSizes),
    ("ui-loader--basic", loaderBasic),
    ("ui-loader--sizes", loaderSizes),
    ("components-progress--basic", progressBasic),
    ("components-progress--no-label", progressNoLabel),
    ("components-progress--indeterminate", progressIndeterminate),
    ("ui-segmented-control--basic", segmentedBasic),
    ("ui-segmented-control--controlled", segmentedControlled),
    ("rune-keybind--symbols", keybindSymbols),
    ("rune-switch--sizes", switchSizes),
    ("rune-scroll-view--thumb", scrollViewThumb),
    ("rune-rolling-text--basic", rollingTextBasic),
    ("rune-markdown--basic", markdownBasic),
    ("rune-markdown--streaming", markdownStreaming),
    ("rune-markdown--stream-tail", markdownStreamTail),
    ("rune-markdown--walkthrough", markdownWalkthrough),
    ("rune-markdown--diagrams", markdownDiagrams),
    ("rune-markdown--lenient", markdownLenient),
    ("rune-markdown--mermaid-shapes", markdownMermaidShapes),
    ("rune-markdown--mermaid-charts", markdownMermaidCharts),
    ("rune-markdown--mermaid-maps", markdownMermaidMaps),
    ("rune-markdown--mermaid-git", markdownMermaidGit),
    ("rune-markdown--mermaid-data", markdownMermaidData),
    ("rune-markdown--mermaid-systems", markdownMermaidSystems),
    ("rune-markdown--mermaid-flows", markdownMermaidFlows),
    ("rune-markdown--mermaid-hover", markdownMermaidHover),
    ("rune-markdown--mermaid-streaming", markdownMermaidStreaming),
    ("rune-markdown--mermaid-plan", markdownMermaidPlan),
    ("rune-markdown--mermaid-plan-zoomed", markdownMermaidPlanZoomed),
    ("rune-markdown--table-styles", markdownTableStyles),
    ("rune-markdown--code", markdownCode),
    ("rune-text--selectable-help", textSelectableHelp),
    ("rune-text--truncate-middle", textTruncateMiddle),
    ("rune-dialog--fit", dialogFit),
    ("rune-popup-list--composer", popupListComposer),
    ("rune-scroll-bar--basic", scrollBarBasic),
    ("rune-scroll-bar--grow", scrollBarGrow),
    ("components-file-icon--samples", fileIconSamples),
    ("components-file-icon--folder", fileIconFolder),
    ("ui-icon--gallery", iconGallery),
    ("rune-icon--catalog", iconCatalog),
    ("rune-file-icon--catalog", fileIconCatalog),
    ("rune-tree-icon--catalog", treeIconCatalog),
    ("rune-tree--files", fileTreeStory),
]

/// Overlay key automatically opened when snapshotting a given story ID (`OPENED` in upstream `stories.rs`).
public func initialOpenOverlay(for storyId: String) -> String? {
    switch storyId {
    case "ui-dialog--basic": return "dialog"
    case "rune-dialog--fit": return "dialog-fit"
    case "rune-popup-list--composer": return "popup-list"
    case "ui-select--playground", "ui-select--grouped", "rune-select--states": return "select"
    case "components-popover--basic", "components-popover--controlled": return "popover"
    case "ui-menu--basic", "ui-menu--rich", "ui-menu--with-checkbox", "ui-menu--with-radio", "ui-menu--with-submenu": return "menu"
    case "ui-menu--appearances": return "both"
    case "ui-tooltip--simple", "ui-tooltip--with-keybind", "ui-tooltip--path", "ui-tooltip--title-description": return "tip"
    case "components-hover-card--basic": return "card"
    case "ui-toast--all-examples": return "toast"
    default: return nil
    }
}

public func galleryIndexView(_ s: GalleryState, _ k: Kit) -> El<GalleryState> {
    let q = s.edits[0].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let visible = galleryStories.filter { q.isEmpty || $0.id.lowercased().contains(q) }
    var rows: El<GalleryState> = col().wFull().gap(4)
    for item in visible {
        let storyId = item.id
        rows = rows.child(
            k.listItem(key: "index-\(storyId)", title: storyId) { st, _ in
                applyStorySetup(&st, storyId: storyId)
            }
        )
    }
    return col().wFull().gap(12)
        .child(
            row().wFull().itemsCenter().justifyBetween()
                .child(text("rune-kit gallery (\(galleryStories.count) stories)").font(k.ty.uiMedium).color(k.c.textBase))
                .child(k.searchField(key: "index-search", \.edits[0], placeholder: "Filter stories…").w(260))
        )
        .child(col().wFull().h(380).scroll().child(rows))
}

public func applyStorySetup(_ state: inout GalleryState, storyId: String) {
    state.story = storyId
    state.open = initialOpenOverlay(for: storyId)
    state.comboOpen = (storyId == "rune-combobox--searchable" || storyId == "rune-combobox--animated-filter")
    state.comboActive = 0
    if storyId == "rune-popup-list--composer" {
        state.edits[7] = TextEdit("/")
    }
}

public func renderGalleryStory(_ s: GalleryState, _ k: Kit, overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    if let match = galleryStories.first(where: { $0.id == s.story }) {
        return match.render(s, k, &overlays)
    }
    return galleryIndexView(s, k)
}

public func galleryView(_ s: GalleryState, _ cx: inout Cx<GalleryState>) -> El<GalleryState> {
    if s.reduced {
        cx.reducedMotion(true)
    }
    let k = resolveGalleryKit(s, dark: cx.systemDark)
    var overlays: [El<GalleryState>] = []
    let body = renderGalleryStory(s, k, overlays: &overlays)
    var root: El<GalleryState> = col()
        .key("frame")
        .sizeFull()
        .bg(k.c.page)
        .p(24)
        .child(body)
    for ov in overlays {
        root = root.child(ov)
    }
    return root
}

public func galleryHandleKey(_ s: inout GalleryState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    if s.comboOpen {
        let filtered = filteredGalleryModels(query: s.edits[5].text)
        switch ev.key {
        case .escape:
            s.comboOpen = false
            return true
        case .arrowUp:
            if !filtered.isEmpty {
                let cur = min(max(s.comboActive, 0), filtered.count - 1)
                s.comboActive = (cur + filtered.count - 1) % filtered.count
            }
            return true
        case .arrowDown:
            if !filtered.isEmpty {
                let cur = min(max(s.comboActive, 0), filtered.count - 1)
                s.comboActive = (cur + 1) % filtered.count
            }
            return true
        case .enter:
            if !filtered.isEmpty {
                let idx = min(max(s.comboActive, 0), filtered.count - 1)
                s.pick["model"] = filtered[idx].id
                s.comboOpen = false
            }
            return true
        case .backspace:
            if !s.edits[5].text.isEmpty {
                s.edits[5] = TextEdit(String(s.edits[5].text.dropLast()))
                s.comboActive = 0
            }
            return true
        case .text(let ch):
            if !ev.mods.cmd && !ev.mods.ctrl && !ev.mods.alt {
                s.edits[5] = TextEdit(s.edits[5].text + ch)
                s.comboActive = 0
                return true
            }
            return false
        default:
            return false
        }
    }
    if ev.key == .escape, s.open != nil {
        s.open = nil
        return true
    }
    return false
}

@main
public enum RuneKitGalleryApp {
    public static func buildSpec() -> AppSpec<GalleryState> {
        var spec = AppSpec<GalleryState>(
            title: "rune-kit gallery",
            size: Vec2(720, 480),
            dark: true,
            state: GalleryState.initFromArgs(),
            onKey: galleryHandleKey,
            view: galleryView
        )
        spec = spec.scene("index") { st in
            st.story = "index"
            st.open = nil
            st.comboOpen = false
        }
        for story in galleryStories {
            let storyId = story.id
            spec = spec.scene(storyId) { st in
                applyStorySetup(&st, storyId: storyId)
            }
        }
        return spec
    }

    public static func main() throws {
        try RuneApp.run(buildSpec())
    }
}
