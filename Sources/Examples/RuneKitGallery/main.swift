import Foundation
import OpenCodeTheme
import Rune
import RuneKit

/// Port of `examples/kit-gallery`: interactive component gallery showcasing `RuneKit` widgets
/// styled with `OpenCodeTheme.kit(dark:)`, `Kit.neutral(dark:)`, and `Kit.fromPalette(...)`.
enum GalleryStory: String, CaseIterable, CustomStringConvertible {
    case buttons = "Buttons & Badges"
    case controls = "Controls & Inputs"
    case progress = "Progress & Feedback"
    case layout = "Tabs & Accordion"
    case data = "Tree & Table"
    case markdown = "Markdown"

    var description: String { rawValue }
}

enum GalleryThemeMode: String, CaseIterable, CustomStringConvertible {
    case opencode = "OpenCode"
    case neutral = "Neutral"
    case crimson = "Palette"

    var description: String { rawValue }
}

struct GalleryState {
    var story: GalleryStory = .buttons
    var themeMode: GalleryThemeMode = .opencode
    var dark: Bool = true

    // Controls state
    var switchA: Bool = true
    var switchB: Bool = false
    var checkA: Bool = true
    var checkB: Bool = false
    var segment: String = "day"
    var sliderVal: Float = 0.62
    var search = TextEdit("")
    var nameInput = TextEdit("OpenCode Studio")

    // Progress & Feedback
    var progressVal: Float = 0.65
    var counter: Int = 42
    var showToast: Bool = false

    // Layout
    var activeTab: String = "overview"
    var expandedAccordions: Set<String> = ["acc-1"]
    var collapsibleOpen: Bool = true
}

private func resolveKit(_ s: GalleryState) -> Kit {
    switch s.themeMode {
    case .opencode:
        return OpenCodeTheme.kit(dark: s.dark)
    case .neutral:
        return Kit.neutral(dark: s.dark)
    case .crimson:
        let seed = s.dark
            ? PaletteSeed(bg: Color.hex("#0a0a0a")!, fg: Color.hex("#ededed")!, accent: Color.hex("#e5484d")!)
            : PaletteSeed(bg: Color.hex("#ffffff")!, fg: Color.hex("#171717")!, accent: Color.hex("#e5484d")!)
        return Kit.fromPalette(seed, focus: .accent)
    }
}

private func buttonsStory(_ s: GalleryState, kit: Kit) -> El<GalleryState> {
    let row1: El<GalleryState> = row().gap(10).itemsCenter()
        .child(kit.button(key: "b-primary", "Primary", variant: .primary) { st, _ in st.counter += 1 })
        .child(kit.button(key: "b-accent", "Accent", variant: .accent) { st, _ in st.counter += 1 })
        .child(kit.button(key: "b-neutral", "Neutral", variant: .neutral) { st, _ in st.counter += 1 })
        .child(kit.button(key: "b-ghost", "Ghost", variant: .ghost) { st, _ in st.counter += 1 })
        .child(kit.button(key: "b-danger", "Danger", variant: .danger) { st, _ in st.counter += 1 })

    let row2: El<GalleryState> = row().gap(10).itemsCenter()
        .child(kit.button(key: "b-sm", "Small", variant: .neutral, size: .sm) { st, _ in st.counter += 1 })
        .child(kit.button(key: "b-dis", "Disabled", variant: .neutral, disabled: true) { _, _ in })

    let variantsCard: El<GalleryState> = kit.card(
        key: "btn-variants-card",
        col().wFull().gap(12)
            .child(text("Button Variants").font(kit.ty.uiMedium).color(kit.c.textBase))
            .child(row1)
            .child(row2)
    )

    let spacerEl: El<GalleryState> = el().grow(1)
    let badgesRow: El<GalleryState> = row().gap(8).itemsCenter()
        .child(kit.badge("Neutral", tone: .neutral))
        .child(kit.badge("Success", tone: .success))
        .child(kit.badge("Warning", tone: .warning))
        .child(kit.badge("Danger", tone: .danger))
        .child(kit.badge("Info", tone: .info))
        .child(spacerEl)
        .child(kit.keybind(["⌘", "K"]))
        .child(kit.keybind(["⇧", "Enter"], variant: .outline))

    let badgesCard: El<GalleryState> = kit.card(
        key: "badges-card",
        col().wFull().gap(12)
            .child(text("Badges & Keybinds").font(kit.ty.uiMedium).color(kit.c.textBase))
            .child(badgesRow)
    )

    return col().wFull().gap(18)
        .child(variantsCard)
        .child(badgesCard)
}

private func controlsStory(_ s: GalleryState, kit: Kit) -> El<GalleryState> {
    let switchesRow: El<GalleryState> = row().wFull().itemsCenter().justifyBetween()
        .child(text("Switches").font(kit.ty.uiMedium).color(kit.c.textBase))
        .child(
            row().gap(14).itemsCenter()
                .child(kit.switchControl(key: "sw-a", isOn: s.switchA, label: "Auto-save") { st, _ in st.switchA.toggle() })
                .child(kit.switchControl(key: "sw-b", isOn: s.switchB, label: "Telemetry") { st, _ in st.switchB.toggle() })
        )

    let checksRow: El<GalleryState> = row().wFull().itemsCenter().justifyBetween()
        .child(text("Checkboxes").font(kit.ty.uiMedium).color(kit.c.textBase))
        .child(
            row().gap(14).itemsCenter()
                .child(kit.checkbox(key: "chk-a", checked: s.checkA, label: "Format on save") { st, _ in st.checkA.toggle() })
                .child(kit.checkbox(key: "chk-b", checked: s.checkB, label: "Strict lint") { st, _ in st.checkB.toggle() })
        )

    let segEl: El<GalleryState> = kit.segmentedControl(
        key: "seg",
        options: [("day", "Day"), ("week", "Week"), ("month", "Month")],
        selected: s.segment
    ) { st, picked in
        st.segment = picked
    }.w(220)

    let segRow: El<GalleryState> = row().wFull().itemsCenter().justifyBetween()
        .child(text("Segmented").font(kit.ty.uiMedium).color(kit.c.textBase))
        .child(segEl)

    let togglesCard: El<GalleryState> = kit.card(
        key: "toggles-card",
        col().wFull().gap(12)
            .child(switchesRow)
            .child(kit.divider())
            .child(checksRow)
            .child(kit.divider())
            .child(segRow)
    )

    let sliderEl: El<GalleryState> = kit.slider(key: "slider", value: s.sliderVal) { st, v in
        st.sliderVal = v
    }.grow(1)

    let sliderRow: El<GalleryState> = row().wFull().itemsCenter().gap(12)
        .child(text("Opacity \(Int((s.sliderVal * 100).rounded()))%").font(kit.ty.small).color(kit.c.textMuted).w(90))
        .child(sliderEl)

    let inputsCard: El<GalleryState> = kit.card(
        key: "inputs-card",
        col().wFull().gap(12)
            .child(kit.searchField(key: "search", \.search, placeholder: "Search components…"))
            .child(kit.textInputField(key: "name", \.nameInput, placeholder: "Project name"))
            .child(sliderRow)
    )

    return col().wFull().gap(16)
        .child(togglesCard)
        .child(inputsCard)
}

private func progressStory(_ s: GalleryState, kit: Kit) -> El<GalleryState> {
    let spacerEl: El<GalleryState> = el().grow(1)
    let actRow: El<GalleryState> = row().gap(16).itemsCenter()
        .child(kit.progressCircle(key: "prog-ring", fraction: s.progressVal, diameter: 36, strokeWidth: 3.5))
        .child(kit.spinner(key: "spin", size: 22))
        .child(kit.loader(key: "load", label: "Indexing workspace…"))
        .child(spacerEl)
        .child(kit.rollingText(key: "roll", "\(s.counter)", font: kit.ty.uiMedium, color: kit.c.textBase))
        .child(kit.button(key: "inc", "+10%", variant: .neutral, size: .sm) { st, _ in
            st.progressVal = st.progressVal >= 0.99 ? 0.15 : min(1.0, st.progressVal + 0.1)
            st.counter += 1
        })

    let progCard: El<GalleryState> = kit.card(
        key: "prog-card",
        col().wFull().gap(14)
            .child(text("Progress & Activity").font(kit.ty.uiMedium).color(kit.c.textBase))
            .child(kit.progress(key: "prog-bar", fraction: s.progressVal))
            .child(actRow)
    )

    let toastCard: El<GalleryState> = kit.card(
        key: "toast-card",
        row().wFull().itemsCenter().justifyBetween()
            .child(text("Toast Notification").font(kit.ty.uiMedium).color(kit.c.textBase))
            .child(kit.button(key: "toggle-toast", s.showToast ? "Hide Toast" : "Show Toast", variant: .accent, size: .sm) { st, _ in
                st.showToast.toggle()
            })
    )

    return col().wFull().gap(16)
        .child(progCard)
        .child(toastCard)
}

private func layoutStory(_ s: GalleryState, kit: Kit) -> El<GalleryState> {
    let tabs = [
        TabItem(id: "overview", title: "Overview", closable: false),
        TabItem(id: "tokens", title: "Tokens", closable: false),
        TabItem(id: "motion", title: "Motion", dirty: true, closable: false),
    ]
    let accItems: [AccordionItem<GalleryState>] = [
        AccordionItem(id: "acc-1", title: "Semantic Palette") {
            text("All surface, border, and text roles resolve from OpenCodeTheme or PaletteSeed.")
                .font(kit.ty.small).color(kit.c.textMuted)
        },
        AccordionItem(id: "acc-2", title: "Spring Presets") {
            text("Controls, overlays, and disclosures share calibrated analytic springs.")
                .font(kit.ty.small).color(kit.c.textMuted)
        },
    ]

    let tabStripEl: El<GalleryState> = kit.tabStrip(key: "tabs", tabs: tabs, selected: s.activeTab) { st, id in
        st.activeTab = id
    }
    let accEl: El<GalleryState> = kit.accordion(key: "acc", items: accItems, expanded: s.expandedAccordions) { st, id, open in
        if open { st.expandedAccordions.insert(id) } else { st.expandedAccordions.remove(id) }
    }
    let collEl: El<GalleryState> = kit.collapsible(
        key: "coll",
        title: "Collapsible Section",
        isOpen: s.collapsibleOpen,
        onToggle: { st, open in st.collapsibleOpen = open },
        content: { text("Expanded content inside Kit.collapsible.").font(kit.ty.small).color(kit.c.textMuted) }
    )

    return col().wFull().gap(16)
        .child(tabStripEl)
        .child(accEl)
        .child(collEl)
}

private func dataStory(_ s: GalleryState, kit: Kit) -> El<GalleryState> {
    let treeRoots: [TreeItem<String>] = [
        TreeItem(id: "src", label: "Sources", isFolder: true, children: [
            TreeItem(id: "rune", label: "Rune", isFolder: true, children: [
                TreeItem(id: "el-swift", label: "El.swift", isFolder: false)
            ]),
            TreeItem(id: "kit", label: "RuneKit", isFolder: true, children: [
                TreeItem(id: "kit-swift", label: "Kit.swift", isFolder: false)
            ]),
        ])
    ]
    struct PkgRow { var name: String; var kind: String; var status: String }
    let rows = [
        PkgRow(name: "RuneRef", kind: "Library", status: "Ready"),
        PkgRow(name: "RuneMotion", kind: "Library", status: "Ready"),
        PkgRow(name: "RuneKit", kind: "Library", status: "Ready"),
    ]
    let cols: [TableColumn<PkgRow>] = [
        TableColumn(title: "Target", width: 160) { $0.name },
        TableColumn(title: "Kind", width: 100) { $0.kind },
        TableColumn(title: "Status") { $0.status },
    ]
    let treeCard: El<GalleryState> = kit.card(
        key: "tree-card",
        kit.tree(
            key: "tree",
            roots: treeRoots,
            expanded: ["src", "kit"],
            selected: "kit-swift",
            onToggleExpand: { _, _ in },
            onSelect: { _, _ in }
        )
    ).w(220)
    let tableCard: El<GalleryState> = kit.card(
        key: "table-card",
        kit.table(key: "tbl", columns: cols, rows: rows)
    ).grow(1)

    return col().wFull().gap(16)
        .child(
            row().wFull().gap(14)
                .child(treeCard)
                .child(tableCard)
        )
}

private func markdownStory(kit: Kit) -> El<GalleryState> {
    let sample = """
    # OpenCode UI Kit

    Rendered natively in **Rune** with `OpenCodeTheme` tokens:

    - Crisp SDF rounded boxes & shadows
    - Analytic `RuneMotion` spring transitions
    - Full keyboard & pointer hit-testing
    """
    return kit.card(key: "md-card", kit.markdown(sample, key: "md"))
}

func galleryView(_ s: GalleryState, _ cx: inout Cx<GalleryState>) -> El<GalleryState> {
    let kit = resolveKit(s)

    var sidebar: El<GalleryState> = col()
        .key("sidebar")
        .w(210)
        .hFull()
        .p(14)
        .gap(4)
        .bg(kit.c.layer01)
        .child(text("RuneKit Gallery").font(kit.ty.uiMedium).color(kit.c.textBase).pb(8))

    for story in GalleryStory.allCases {
        let active = (story == s.story)
        let navRow: El<GalleryState> = row()
            .key("nav-\(story.rawValue)")
            .wFull()
            .h(30)
            .px(10)
            .itemsCenter()
            .rounded(kit.radius.sm)
            .bg(active ? kit.c.layer03 : .transparent)
            .hover(active ? kit.c.layer03 : kit.c.hover)
            .onClick { st in st.story = story }
            .child(text(story.rawValue).font(kit.ty.smallMedium).color(active ? kit.c.textBase : kit.c.textMuted))
        sidebar = sidebar.child(navRow)
    }

    let themeSeg: El<GalleryState> = kit.segmentedControl(
        key: "theme-mode",
        options: GalleryThemeMode.allCases.map { ($0, $0.description) },
        selected: s.themeMode
    ) { st, mode in
        st.themeMode = mode
    }.w(220)

    let darkBtn: El<GalleryState> = kit.button(key: "dark-toggle", s.dark ? "Dark" : "Light", variant: .neutral, size: .sm) { st, _ in
        st.dark.toggle()
    }

    let topBar: El<GalleryState> = row()
        .wFull()
        .itemsCenter()
        .justifyBetween()
        .child(text(s.story.rawValue).size(18).semibold().color(kit.c.textBase))
        .child(row().gap(10).itemsCenter().child(themeSeg).child(darkBtn))

    let storyBody: El<GalleryState>
    switch s.story {
    case .buttons: storyBody = buttonsStory(s, kit: kit)
    case .controls: storyBody = controlsStory(s, kit: kit)
    case .progress: storyBody = progressStory(s, kit: kit)
    case .layout: storyBody = layoutStory(s, kit: kit)
    case .data: storyBody = dataStory(s, kit: kit)
    case .markdown: storyBody = markdownStory(kit: kit)
    }

    let sep: El<GalleryState> = el().w(1).hFull().bg(kit.c.borderBase)
    let stage: El<GalleryState> = col()
        .key("stage")
        .grow(1)
        .hFull()
        .p(24)
        .gap(18)
        .scroll()
        .child(topBar)
        .child(storyBody)

    var root: El<GalleryState> = row()
        .key("root")
        .sizeFull()
        .bg(kit.c.page)
        .child(sidebar)
        .child(sep)
        .child(stage)

    if s.showToast {
        let toastEl: El<GalleryState> = el()
            .absolute(x: 240, y: 20)
            .child(kit.toast(key: "toast", message: "Theme tokens synced", tone: .success) { st in
                st.showToast = false
            })
        root = root.child(toastEl)
    }

    return root
}

let spec = AppSpec<GalleryState>(
    title: "RuneKit Gallery",
    size: Vec2(920, 600),
    dark: true,
    state: GalleryState(),
    view: galleryView
)
.scene("buttons") { $0.story = .buttons }
.scene("controls") { $0.story = .controls }
.scene("progress") { $0.story = .progress; $0.showToast = true }
.scene("layout") { $0.story = .layout }
.scene("data") { $0.story = .data }
.scene("markdown") { $0.story = .markdown }

try RuneApp.run(spec)
