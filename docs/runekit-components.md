# RuneKit Component Guide

`RuneKit` is the batteries-included, WCAG-contrast-checked UI component library built on top of `Rune` and `RuneMotion`. Add `.product(name: "RuneKit", package: "swift-rune")` to your target and `import RuneKit`.

## 1. Theming with `Kit`

Generate a complete, cohesive 50+ token palette (surfaces, borders, text hierarchy, elevation shadows, focus rings, status tones, typography, radii, and motion springs) from a three-color `PaletteSeed`:

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

Switch smoothly between dark and light themes by constructing `PaletteSeed` from `cx.systemDark` (or user state).

### Key `Kit` Token Groups

- **`kit.c`** (`Palette`) — `page`, `bgBase`, `surfaceRaised`, `surfaceWeak`, `layer01`..`layer04`, `textBase`, `textMuted`, `textFaint`, `textAccent`, `borderBase`, `borderMuted`, `borderFocus`, `hover`, `pressed`, plus status bundles (`success`, `warning`, `danger`, `info`).
- **`kit.ty`** — Typography scale (`ui`, `uiMedium`, `uiCompact`, `body`, `bodyMedium`, `small`, `smallMedium`, `textSmall`, `textSmallMedium`, `mono`, `caption()`).
- **`kit.radius`** — Corner radii (`xs`, `sm`, `md`, `lg`, `xl`).
- **`kit.elevation`** — Layered shadow presets (`raised`, `floating`, `overlay`, `knob`, `input`).
- **`kit.motion`** — Standard component springs (`control`, `disclosure`, `overlay`).

> **Pre-built Theme:** Add `.product(name: "OpenCodeTheme", package: "swift-rune")` for ready-to-use OpenCode dark/light palettes and SVG icon sets.

---

## 2. Two Ergonomic Styles

Most `RuneKit` components support both:

1. **Direct `kit.*` helpers** — Fast, concise calls directly on `Kit`:
   ```swift
   kit.button(key: "save", "Save Changes", variant: .primary) { state, _ in
       state.save()
   }
   ```
2. **Fluent builders** — Chainable structs ending in `.build(kit)` when you need extra options like shortcuts, tooltips, or custom labels:
   ```swift
   Button<MyState>(key: "save", "Save Changes")
       .variant(.primary)
       .size(.regular)
       .shortcut("Cmd+S")
       .help("Save the current document")
       .onPress { state, _ in state.save() }
       .build(kit)
   ```

---

## 3. Component Catalog

### Buttons & Actions

- **`kit.button(key:_:variant:size:leadingIcon:trailingIcon:disabled:onClick:)`**
  Variants: `.neutral`, `.primary`, `.accent`, `.outline`, `.ghost`, `.ghostMuted`, `.ghostFaint`, `.danger`, `.warning`, `.loading`.
  Sizes: `.mini`, `.small`/`.sm`, `.regular`/`.md`, `.large`/`.lg`, `.extraLarge`.
- **`kit.iconButton(key:svg:label:size:variant:disabled:onClick:)`** — Compact square icon button with accessible label and tooltip.
- **`Button` / `IconButton` / `ActionItem` / `ActionDispatcher`** — Command-palette and toolbar action dispatching with keyboard shortcut formatting.

```swift
row().gap(8)
    .child(kit.button(key: "ok", "Deploy", variant: .primary) { s, _ in s.deploy() })
    .child(kit.button(key: "cancel", "Cancel", variant: .outline) { s, _ in s.cancel() })
    .child(kit.iconButton(key: "close", svg: KitIcons.close, label: "Close", variant: .ghost) { s, _ in s.close() })
```

### Toggles, Choices & Sliders

- **`kit.switchControl(key:isOn:label:disabled:onToggle:)`** (and `Switch` builder) — Animated toggle switch.
- **`kit.checkbox(key:checked:indeterminate:label:disabled:onToggle:)`** (and `Checkbox` builder) — Supports checked, unchecked, and indeterminate states.
- **`RadioGroup` / `RadioItem`** — Accessible single-choice radio groups.
- **`Segmented`** — Animated sliding-indicator segmented control.
- **`Slider`** — Continuous/stepped value slider with keyboard and drag interaction.
- **`ShortcutRecorder`** — Interactive keyboard shortcut capture control.

```swift
col().gap(10)
    .child(
        kit.switchControl(key: "autosave", isOn: state.autoSave, label: "Auto-save") { s, on in
            s.autoSave = on
        }
    )
    .child(
        kit.checkbox(key: "terms", checked: state.accepted, label: "Accept license") { s, checked in
            s.accepted = checked
        }
    )
```

### Text Inputs & Form Fields

- **`kit.textInputField(key:_:placeholder:leadingIcon:invalid:onChange:onSubmit:)`** (and `TextInput` builder) — Single-line text input bound to a `TextEdit` key path.
- **`kit.textArea(key:_:placeholder:minHeight:invalid:onChange:)`** — Multi-line text editor.
- **`kit.field(label:description:error:control:)`** (and `Field` builder) — Form row with label, helper text, and validation error message.
- **`Select` / `Combobox` / `PopupList`** — Searchable and keyboard-navigable option pickers.

```swift
kit.field(
    label: "Workspace Name",
    description: "Shown in the window titlebar.",
    error: state.nameError,
    control: kit.textInputField(
        key: "ws-name",
        \AppState.workspaceName,
        placeholder: "e.g. Core Engine",
        invalid: state.nameError != nil
    )
)
```

### Containers, Disclosures & Feedback

- **`kit.card(key:padding:_:)`** (and `Card` builder) — Elevated surface container.
- **`kit.divider()` / `kit.dividerVertical()`** — Hairline separators.
- **`kit.badge(_:tone:)`** — Status pill (`.neutral`, `.accent`, `.success`, `.warning`, `.danger`, `.info`).
- **`kit.progress(key:fraction:height:)`** & **`kit.progressCircle(key:fraction:diameter:)`** — Linear and radial progress indicators.
- **`kit.spinner(key:size:)`**, **`RadarSpinner`**, **`RingLoader`** — Activity indicators.
- **`kit.collapsible(key:title:isOpen:onToggle:content:)`** & **`kit.accordion(key:items:expanded:onToggle:)`** — Animated disclosure panels.
- **`kit.list(key:items:)`** & **`kit.listItem(key:title:subtitle:leading:trailing:selected:onClick:)`** — Focus-grouped selectable lists.
- **`RollingText`** — Animated digit/text odometer transitions.

### Overlays, Menus & Notifications

- **`Dialog`** & **`kit.scrim(key:onDismiss:)`** — Modal dialogs with backdrop dismissal and spring transitions.
- **`Menu` / `MenuItem` / `kit.menu(key:entries:)`** — Dropdown and context menus with shortcuts, badges, icons, checkmarks, and submenus.
- **`kit.popover(key:isOpen:placement:trigger:content:)`** & **`kit.hoverCard(...)`** — Anchored floating panels.
- **`kit.tooltip(key:text:placement:isVisible:trigger:)`** — Hover/focus tooltips.
- **`ToastStack`** — Stacked transient toast notifications.

### Desktop App Shell

Build IDE-style or studio layouts with `RuneKit`'s shell primitives:

- **`kit.sidebar(key:pane:title:content:onToggle:)`** — Collapsible/peekable sidebar backed by `PaneState`.
- **`kit.paneGroup(key:group:onSelectTab:onCloseTab:renderContent:)`** & **`TabStrip`** — Multi-tab document strip with dirty indicators and close buttons.
- **`kit.statusBar(key:leading:trailing:)`** — Bottom status bar.
- **`WindowTitlebar`**, **`splitView`**, **`toolbar`**, **`ScrollBar`** — Complete desktop window chrome and split panes.

### Rich Data & Developer UI

- **Virtualized `Table`** — High-throughput tabular views (benchmarked at 100,000+ rows).
- **Virtualized `TreeView` / `FileTree`** — Expandable hierarchical file/outline trees (benchmarked at 50,000+ nodes).
- **Streaming `Markdown`** — Native GPU-rendered Markdown with headings, tables, code fences, links, and inline formatting.
- **`Kit.syntax`** (`RuneHighlights`) — Zero-dependency syntax highlighting for 100+ languages.
- **`Kit.mermaid`** (`RuneMermaid`) — Native vector Mermaid diagrams (17 diagram families including flowcharts, sequence, state, class, ER, Gantt, mindmaps, and XY charts).
- **`FileDiff` / `diffView`** — Unified and split code diff viewer.
- **`ImageZoom`** — Pan/zoom image lightbox.

---

## Live Examples in This Repository

Run these built-in examples to see `RuneKit` components in action:

```bash
swift run rune-kit-gallery      # Full interactive component gallery
swift run rune-settings         # Theme, accent, and motion settings panel
swift run rune-kit-shell        # Sidebar + split panes + tab strip shell
swift run rune-kit-table        # High-performance virtualized table
swift run rune-kit-tree         # Expandable file tree
swift run rune-kit-diff         # Code diff viewer
swift run rune-kit-rich-editor  # Rich text editor
```

You can also inspect the standalone SwiftPM app in [`examples/SparkStudio`](../examples/SparkStudio) for a full real-world example consuming `Rune`, `RuneKit`, and `RuneMotion` as external package products.
