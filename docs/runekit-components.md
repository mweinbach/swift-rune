# RuneKit Component Guide & Recipes

`RuneKit` is the batteries-included, WCAG-contrast-checked UI component library built on top of `Rune` and `RuneMotion`. Add `.product(name: "RuneKit", package: "swift-rune")` to your target and `import RuneKit`.

---

## 1. Theming with `Kit`

### Deriving a Full Theme from Three Colors (`Kit.fromPalette`)

`Kit.fromPalette` generates 50+ semantic color tokens (surfaces, elevation layers, borders, text hierarchy, focus rings, hover/press overlays, and success/warning/danger/info status bundles) from a single `PaletteSeed`, automatically checking contrast:

```swift
import Rune
import RuneKit

let kit = Kit.fromPalette(
    PaletteSeed(
        bg: Color.hex("#111318")!,
        fg: Color.hex("#f1f3f5")!,
        accent: Tok.accent(0, dark: true)
    ),
    focus: .accent // .blue, .accent, .ink, or .custom(Color)
)
```

For a neutral out-of-the-box theme that adapts to light/dark mode:

```swift
let kit = Kit.neutral(dark: cx.systemDark)
```

For OpenCode's curated developer themes and SVG icon library, add `.product(name: "OpenCodeTheme", package: "swift-rune")`.

### Token Groups on `Kit`

- **`kit.c`** (`Palette`)
  - Surfaces: `page`, `bgBase`, `bgDeep`, `layer01`..`layer04`, `surfaceBase`, `surfaceWeak`, `surfaceRaised`, `surfaceFloat`, `surfaceDisabled`, `bgAccent`, `bgContrast`, `bgInverse`
  - Text & Icons: `textBase`, `textMuted`, `textFaint`, `textInverse`, `textContrast`, `textAccent`, `iconBase`, `iconMuted`, `iconFaint`, `iconAccent`
  - Borders & Interactive: `borderMuted`, `borderBase`, `borderStrong`, `borderFocus`, `hover`, `pressed`, `scrim`
  - Semantic status bundles (`StateColors` with `.bg`, `.fg`, `.border`, `.icon`): `success`, `warning`, `danger`, `info`
- **`kit.ty`** (`KitTypography`) — `ui`, `uiMedium`, `uiCompact`, `body`, `bodyMedium`, `small`, `smallMedium`, `textSmall`, `textSmallMedium`, `textXsmall`, `textXsmallMedium`, `mono`, `caption()`
- **`kit.radius`** (`KitRadius`) — `xs`, `sm`, `md`, `lg`, `xl`
- **`kit.elevation`** (`KitElevation`) — `raised`, `floating`, `overlay`, `buttonNeutral`, `buttonContrast`, `knob`, `input`
- **`kit.motion`** (`KitMotion`) — `control`, `overlay`, `disclosure`

---

## 2. Two Ergonomic APIs: Direct Helpers & Fluent Builders

Every core `RuneKit` component is usable either as a concise `kit.*` method or as a fluent builder ending in `.build(kit)`:

```swift
// 1. Concise helper
kit.button(key: "save", "Save", variant: .primary) { state, _ in
    state.save()
}

// 2. Fluent builder (with tooltips, shortcuts, icons, and visual states)
Button<AppState>(key: "save", "Save Changes")
    .variant(.primary)
    .size(.regular)
    .leadingIcon(KitIcons.check)
    .shortcut("mod+s")
    .help("Save the active document")
    .onPress { state, tx in
        state.save()
        tx.announce("Document saved")
    }
    .build(kit)
```

---

## 3. Buttons, Icon Buttons & Action Dispatching

### Variants & Sizes
- **`ButtonVariant`**: `.neutral`, `.primary`, `.accent`, `.outline`, `.ghost`, `.ghostMuted`, `.ghostFaint`, `.danger`, `.warning`, `.loading`
- **`ControlSize`**: `.mini`, `.small`/`.sm`, `.regular`/`.md`, `.large`/`.lg`, `.extraLarge`

### Icon Buttons

```swift
IconButton<AppState>(key: "copy", svg: KitIcons.copy)
    .variant(.ghost)
    .size(.sm)
    .label("Copy snippet")
    .shortcut("mod+c")
    .onPress { state, tx in
        tx.copyText(state.code)
    }
    .build(kit)
```

### Command / Action Dispatching (`ActionItem` & `ActionDispatcher`)

Define actions once and reuse them in toolbars, menus, and command palettes:

```swift
let dispatcher = ActionDispatcher<AppState>(items: [
    ActionItem(id: "new-file", title: "New File", shortcut: "mod+n") { $0.createFile() },
    ActionItem(id: "toggle-theme", title: "Toggle Theme", shortcut: "mod+shift+t") { $0.dark.toggle() },
])
```

---

## 4. Toggles, Selection Controls & Sliders

### Switch & Checkbox

```swift
col().gap(10)
    .child(
        kit.switchControl(key: "autosave", isOn: state.autoSave, label: "Auto-save") { s, on in
            s.autoSave = on
        }
    )
    .child(
        kit.checkbox(
            key: "select-all",
            checked: state.allSelected,
            indeterminate: state.someSelected,
            label: "Select all items"
        ) { s, checked in
            s.setAllSelected(checked)
        }
    )
```

### Radio Group, Segmented Control & Slider

- **`RadioGroup` + `RadioItem`**: Accessible single-choice groups with descriptions and invalid/disabled states.
- **`Segmented`**: Animated pill-sliding segmented control (`onPick { state, index, tx in ... }`).
- **`Slider`**: Drag and keyboard-adjustable range slider.
- **`ShortcutRecorder`**: Interactive key-chord recorder for user-customizable shortcuts.

---

## 5. Form Inputs, Fields & Comboboxes

### Single-Line & Multi-Line Text Inputs

```swift
col().gap(14)
    .child(
        kit.field(
            label: "Project Name",
            description: "Used as the SwiftPM package name.",
            error: state.nameError,
            control: kit.textInputField(
                key: "project-name",
                \AppState.projectName,
                placeholder: "MyAwesomeApp",
                leadingIcon: KitIcons.folder,
                invalid: state.nameError != nil,
                onSubmit: { s, _, _ in s.submit() }
            )
        )
    )
    .child(
        kit.field(
            label: "Description",
            control: kit.textArea(
                key: "project-desc",
                \AppState.description,
                placeholder: "Describe your project...",
                minHeight: 96
            )
        )
    )
```

### Searchable Combobox & Select (Overlay Layer Pattern)

Overlays such as `Combobox`, `Select`, `Menu`, and `Dialog` take an `inout [El<State>]` overlay layer array so their popups render above all clipped containers and scroll views at the root of your window:

```swift
func myView(_ state: AppState, _ cx: inout Cx<AppState>) -> El<AppState> {
    var overlays: [El<AppState>] = []

    let picker = Combobox<AppState>(key: "lang", state: \AppState.langCombo, items: languageItems)
        .label("Language")
        .current(state.selectedLang)
        .placeholder("Select language...")
        .searchPlaceholder("Filter languages...")
        .onChoose { s, id, _ in s.selectedLang = id }
        .build(state, kit: kit, layer: &overlays, cx: cx)

    var root = col()
        .sizeFull()
        .bg(kit.c.page)
        .child(picker)

    // Attach collected overlays last so they paint above everything
    for overlay in overlays {
        root = root.child(overlay)
    }
    return root
}
```

---

## 6. Containers, Disclosures, Lists & Feedback

```swift
kit.card(
    key: "status-card",
    padding: 16,
    col()
        .gap(12)
        .child(
            row().wFull().itemsCenter().justifyBetween()
                .child(text("Build Pipeline").font(kit.ty.uiMedium).color(kit.c.textBase))
                .child(kit.badge("Healthy", tone: .success))
        )
        .child(kit.progress(key: "build-progress", fraction: state.progress))
        .child(kit.divider())
        .child(
            kit.accordion(
                key: "details",
                items: [
                    AccordionItem(id: "logs", title: "Build Output") {
                        text(state.lastLog).font(kit.ty.mono).color(kit.c.textMuted)
                    }
                ],
                expanded: state.expandedSections
            ) { s, id, open in
                if open { s.expandedSections.insert(id) } else { s.expandedSections.remove(id) }
            }
        )
)
```

Also included:
- **`kit.list(key:items:)`** & **`kit.listItem(key:title:subtitle:leading:trailing:selected:onClick:)`**
- **`kit.progressCircle(key:fraction:diameter:strokeWidth:)`**
- **`kit.spinner(key:size:)`**, **`RadarSpinner`**, **`RingLoader`**
- **`RollingText`** (animated odometer digit transitions)

---

## 7. Menus, Popovers, Tooltips, Dialogs & Toasts

### Context & Dropdown Menus

```swift
Menu<AppState>(key: "file-menu")
    .trigger(kit.button(key: "menu-btn", "Actions") { s, _ in s.menuOpen.toggle() })
    .open(state.menuOpen)
    .item(MenuItem("Duplicate").shortcut("mod+d").onSelect { $0.duplicate() })
    .separator()
    .item(MenuItem("Delete").danger().onSelect { $0.deleteSelected() })
    .onClose { $0.menuOpen = false }
    .build(kit: kit, layer: &overlays, cx: cx)
```

### Tooltips, Popovers, HoverCards & Scrims

```swift
kit.tooltip(
    key: "help-tip",
    text: "Refresh data (Cmd+R)",
    placement: .bottom,
    isVisible: cx.isHovered("refresh-btn"),
    trigger: kit.iconButton(key: "refresh-btn", svg: KitIcons.search, label: "Refresh") { s, _ in
        s.refresh()
    }
)
```

- **`kit.popover(key:isOpen:placement:trigger:content:)`** and **`kit.hoverCard(...)`**
- **`Dialog`** + **`kit.scrim(key:onDismiss:)`** for modal confirmation sheets
- **`ToastStack`** for stacked animated transient notifications

---

## 8. Desktop App Shell (`Sidebar`, `PaneGroup`, `TabStrip`, `StatusBar`)

Build full desktop studio/IDE layouts in a few lines:

```swift
col()
    .sizeFull()
    .bg(kit.c.page)
    .child(
        row()
            .wFull()
            .grow(1)
            .minH(0)
            .child(
                kit.sidebar(
                    key: "explorer",
                    pane: state.sidebarPane,
                    title: "EXPLORER",
                    content: fileTreeView,
                    onToggle: { $0.sidebarPane.isOpen.toggle() }
                )
            )
            .child(
                el().grow(1).minW(0).hFull().child(
                    kit.paneGroup(
                        key: "editor-tabs",
                        group: state.tabs,
                        onSelectTab: { s, id in s.tabs.select(id) },
                        onCloseTab: { s, id in s.tabs.close(id) }
                    ) { doc in
                        renderDocument(doc)
                    }
                )
            )
    )
    .child(
        kit.statusBar(
            leading: text("main · UTF-8").font(kit.ty.small).color(kit.c.textMuted),
            trailing: kit.badge("Swift 6.4", tone: .accent)
        )
    )
```

Additional shell components in `Sources/RuneKit/Shell.swift` and `SidebarSplit.swift`: `WindowTitlebar`, `splitView`, `toolbar`, `TabStrip`, and `ScrollBar`.

---

## 9. Rich Data & Developer Views

### Virtualized `Table` & `TreeView` / `FileTree`
- **`Table`**: Column-resizable, sortable, keyboard-navigable virtualized table supporting 100,000+ rows at 60–120 fps (`Sources/Examples/RuneKitTable`).
- **`TreeView` & `FileTree`**: Expandable hierarchical tree with keyboard navigation, selection, and lazy virtualization for 50,000+ nodes (`Sources/Examples/RuneKitTree`).

### Streaming `Markdown`
`RuneKit` includes an incremental, memoized Markdown parser and native GPU renderer (`MarkdownParser`, `MarkdownStyle`, `kit.markdown(...)`) supporting headings, tables, task checklists, blockquotes, links, inline code, fenced syntax-highlighted code blocks, and search highlights—built for streaming LLM/chat output and live documentation viewers.

### Syntax Highlighting (`Kit.syntax` / `RuneHighlights`)
Zero-dependency multi-language syntax highlighter supporting 100+ languages with automatic filename, shebang, and content detection.

### Native Diagrams (`Kit.mermaid` / `RuneMermaid`)
Renders 17 Mermaid diagram families (flowchart, sequence, state, class, ER, pie, gantt, timeline, journey, gitGraph, mindmap, quadrant, xychart, sankey, block, C4, requirement) directly as crisp GPU vector graphics with no browser or WebView.

### Code Diff Viewer (`FileDiff` / `diffView`)
Unified and side-by-side split diffs with syntax highlighting, collapsible context hunks (`fold(context:)`), line selection, and copy support (`Sources/Examples/RuneKitDiff`).

### Image Lightbox (`ImageZoom`)
Interactive pan-and-zoom image viewer overlay.

---

## Explore Interactive Examples

```bash
swift run rune-kit-gallery      # Interactive gallery of all RuneKit components
swift run rune-settings         # Theme, accent, and motion settings panel
swift run rune-kit-shell        # Multi-pane desktop shell
swift run rune-kit-table        # Virtualized 100k-row table
swift run rune-kit-tree         # Virtualized file tree
swift run rune-kit-diff         # Unified/split code diff viewer
swift run rune-kit-rich-editor  # Rich text editor
```

For a complete standalone SwiftPM consumer app using `Rune`, `RuneKit`, and `RuneMotion`, inspect [`examples/SparkStudio`](../examples/SparkStudio).
