# Rebuilding Apple UIs in swift-rune

If you're coming from **SwiftUI**, **AppKit**, or **UIKit**, `swift-rune` lets you build Apple-caliber interfaces—translucent frosted bars, macOS System Settings panels, Spotlight-style launchers, Liquid Glass cards, unified custom titlebars, and split-view desktop apps—using pure Swift 6 that runs natively on **macOS, iOS, Windows, Linux, Android, and WebAssembly**.

---

## 1. SwiftUI / AppKit / UIKit → Rune Cheat Sheet

| Apple Framework Concept | `swift-rune` Equivalent |
| :--- | :--- |
| `VStack` / `HStack` | `col()` / `row()` |
| `ZStack` / `.overlay` | `el()` + `.absolute(x:y:)` or `.pin(top:right:bottom:left:)` + `.z(_:)` |
| `Spacer()` | `spacer()` or `el().grow(1)` |
| `LazyVGrid` / `Grid` | `grid(columns:rows:)` / `.gridTemplateAreas(...)` |
| `ScrollView` / `List` | `.scroll(...)` / `virtualList` / `RuneKit` `Table` & `TreeView` |
| `@State` / `@Observable` | Plain `State` struct in `AppSpec<State>` or `App<State>` |
| `withAnimation(.spring(...))` | `.animate(Tok.Motion.SNAPPY)` / `.animateLayout(...)` / `tx.motion(...)` |
| `.matchedGeometryEffect(id:in:)` | Stable `.key("...")` + `.animateLayout(Tok.Motion.MORPH)` |
| `.transition(.scale.combined(with: .opacity))` | `.transition(Transition.scale(0.95).combined(with: .opacity).spring(...))` |
| `.background(.ultraThinMaterial)` | `.backdropBlur(12)` + translucent OKLCH `.bg(...)` |
| Native macOS Liquid Glass / `NSVisualEffectView` | `.systemMaterial(.glass)` or `.systemMaterial(.popover)` |
| Cross-platform refractive Liquid Glass | `RuneLight` `Glass(...)` (`ior`, `dispersion`, `frost`, `bevel`, smooth `union`) |
| `NavigationSplitView` | `row()` + `kit.sidebar(...)` + `kit.paneGroup(...)` / `splitView` |
| `TabView` (iOS bottom bar) | `.pin(right: 0, bottom: 0, left: 0).backdropBlur(...)` |
| `.sheet` / `.confirmationDialog` | `Dialog`, `kit.scrim(...)`, or `.modal(clickOutside: true) { ... }` |
| `NSToolbar` / unified titlebar | `App.titlebar(...)` + `.windowDrag()` + `cx.chromeInsets()` |
| `NSPanel` / Spotlight HUD | `App` with `.floatOnOpen()`, `.fitContentHeight()`, `tx.closeWindow()` |
| `NSWindow.setFrameAutosaveName` | `RuneMac` window frame persistence & multi-display clamping |
| `UIHostingController` | `IOSApp.makeViewController(app)` |

---

## 2. macOS System Settings (Grouped Cards, Hairlines & Switches)

Apple's System Settings relies on subtle surface hierarchy, 1-physical-pixel hairline borders, dual-layer ambient + contact shadows, and velocity-preserving spring toggles.

```swift
import Rune

struct SettingsState {
    var darkOverride: Bool? = nil
    var accentIndex: Int = 0
    var launchAtLogin: Bool = true
    var showInMenuBar: Bool = true
}

func settingsCard(
    t: ThemeTokens,
    hair: Float,
    title: String,
    rows: [El<SettingsState>]
) -> El<SettingsState> {
    var card: El<SettingsState> = col()
        .p(Tok.Space.xs)
        .bg(t.card)
        .rounded(Tok.Radius.lg)
        .border(hair, t.cardBorder)
        .shadow(Shadow(x: 0, y: 1, blur: 2, color: t.shadow))
        .shadow(Shadow(x: 0, y: 8, blur: 24, color: t.shadowSoft))

    for (i, item) in rows.enumerated() {
        card = card.child(item)
        if i + 1 < rows.count {
            card = card.child(
                el().h(hair).ml(Tok.Space.md).mr(Tok.Space.md).bg(t.separator)
            )
        }
    }

    return col()
        .gap(Tok.Space.sm)
        .child(text(title).font(Tok.Typography.section).color(t.textSecondary).ml(Tok.Space.md))
        .child(card)
}

func macSwitch(key: String, on: Bool, t: ThemeTokens, accent: Color) -> El<SettingsState> {
    let w: Float = 38, h: Float = 22, k: Float = 18, inset: Float = 2
    return el()
        .key(key)
        .role(.switchControl)
        .size(w, h)
        .rounded(h / 2)
        .bg(on ? accent : t.controlOff)
        .animate(Tok.Motion.SNAPPY)
        .child(
            el()
                .key("knob")
                .size(k, k)
                .absolute(x: on ? (w - k - inset) : inset, y: inset)
                .rounded(k / 2)
                .bg(t.knob)
                .animateLayout(Tok.Motion.SNAPPY)
                .shadow(Shadow(x: 0, y: 1, blur: 3, color: t.knobShadow))
                .shadow(Shadow(x: 0, y: 0, blur: 0.5, color: t.edge))
        )
}
```

**Why it feels native:**
- `let hair = 1.0 / max(1.0, cx.pixelScale)` keeps borders razor-sharp on Retina (2x/3x) and 1x displays alike.
- `Tok.theme(dark:)` and `Tok.accent(0..<6, dark:)` mirror Apple's six perceptual accents (blue, purple, pink, orange, green, graphite) in OKLCH.
- See the full interactive version in `Sources/Examples/RuneSettings` (`swift run rune-settings`).

---

## 3. iOS Frosted Bottom Tab Bar (`backdropBlur`)

Recreate iOS's translucent tab bar scrolling over colorful content using `.backdropBlur(sigma)` pinned to the bottom edge with a `0.5pt` hairline separator:

```swift
func frostedTabBarView(_ s: TabBarState, _ cx: inout Cx<TabBarState>) -> El<TabBarState> {
    let dark = cx.systemDark
    let t = Tok.theme(dark: dark)
    let barHeight: Float = 60
    let tint = dark
        ? oklcha(0.20, 0.005, 265.0, 0.45)
        : oklcha(0.98, 0.003, 265.0, 0.50)

    let scrollContent = col()
        .key("list")
        .sizeFull()
        .scroll(stickBottom: false)
        .child(col().wFull().pb(barHeight).children(s.rows.map(renderRow)))

    let tabBar = col()
        .key("bar")
        .pin(right: 0, bottom: 0, left: 0)
        .h(barHeight)
        .backdropBlur(12.0)              // real-time GPU backdrop blur
        .bg(tint)
        .child(el().wFull().h(0.5).bg(t.separator))
        .child(row().wFull().grow(1).children(renderTabs(s, dark: dark)))

    return el()
        .sizeFull()
        .bg(t.bg)
        .child(scrollContent)
        .child(tabBar)
}
```

Run the full example with `swift run rune-frosted-bar` (`Sources/Examples/RuneFrostedBar`).

---

## 4. Liquid Glass Cards & Dynamic Island Morphing

### Option A: Native Apple Material (`.systemMaterial`)

On Apple platforms, `.systemMaterial(.glass)` and `.systemMaterial(.popover)` attach native system glass/vibrancy that animates in the **exact same transaction** as your Rune layout spring, corner radius, text, and shadows:

```swift
var card = col()
    .key("card")
    .absolute(x: s.docked ? 470 : 70, y: s.docked ? 386 : 60)
    .size(s.docked ? 250 : 400, s.docked ? 60 : 260)
    .rounded(s.docked ? 30 : 28)
    .p(s.docked ? 16 : 26)
    .shadow(Shadow(y: 18, blur: 44, color: Color.black.alpha(0.35)))
    .systemMaterial(.glass)
    .animateLayout(Spring(duration: 0.7, bounce: 0.22))
    .animate(Spring(duration: 0.7, bounce: 0.22))
```

Notice how toggling `s.docked` morphs the card from a large floating sheet into a compact pill ("Dynamic Island" style) on one shared spring. Run `swift run rune-glass-card` (`Sources/Examples/RuneGlassCard`).

### Option B: Cross-Platform Refractive Liquid Glass (`RuneLight`)

When you want refractive glass with chromatic dispersion, physical bevels, rim glow, and smooth liquid-glass metaball unions across **macOS, Windows, Linux, iOS, and Android**, use `RuneLight`:

```swift
import RuneLight

let pill = Glass(rect: SIMD4(120, 120, 260, 120), radius: 28)
    .thickness(18)
    .bevel(12)
    .ior(1.48)
    .dispersion(0.15)
    .frost(0.22)
    .rimGlow(0.35)
    .union(rect: SIMD4(360, 150, 72, 72), radius: 36, k: 24, morph: s.detachAmount)
```

Run `swift run rune-glass-panel` (`Sources/Examples/RuneGlassPanel`).

---

## 5. Spotlight / Raycast Command Launcher

Build a keyboard-first floating launcher with instant filtering, Up/Down selection, Escape to dismiss, and cross-window state updates via `AppHandle`:

```swift
func launcherPanelView(_ s: LauncherState, _ cx: inout Cx<LauncherState>) -> El<LauncherState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)
    let matches = s.filteredItems()

    let searchField = textInput(key: "query", \.query)
        .autofocus()
        .grow(1)
        .font(Tok.Typography.body.lh(26))
        .color(t.text)
        .placeholder("Search notes, commands, files...", color: t.textSecondary)
        .onKey { state, ev, tx in
            let count = state.filteredItems().count
            switch ev.key {
            case .arrowDown where count > 0:
                state.picked = (state.picked + 1) % count
                return true
            case .arrowUp where count > 0:
                state.picked = (state.picked + count - 1) % count
                return true
            case .escape:
                tx.closeWindow()
                return true
            default:
                return false
            }
        }
        .onChange { state, _, _ in state.picked = 0 }
        .onSubmit { state, _, tx in
            state.openSelected(tx: &tx)
        }

    var results = col().key("results").p(6).gap(2)
    for (idx, item) in matches.enumerated() {
        let selected = idx == s.picked
        results = results.child(
            row()
                .key("result-\(item.id)")
                .h(36).px(12).rounded(8).itemsCenter()
                .bg(selected ? accent.alpha(0.85) : .transparent)
                .child(text(item.title).color(selected ? .white : t.text))
                .onClick { state, tx in
                    state.picked = idx
                    state.openSelected(tx: &tx)
                }
        )
    }

    return col()
        .key("panel")
        .wFull()
        .rounded(14)
        .clip(true)
        .backdropBlur(18)
        .bg(t.card.alpha(0.85))
        .border(1, Color.white.alpha(0.12))
        .shadow(Shadow(y: 20, blur: 48, color: Color.black.alpha(0.45)))
        .child(
            row().h(56).px(18).gap(12).itemsCenter()
                .child(icon(KitIcons.search, size: 18).color(t.textSecondary))
                .child(searchField)
        )
        .child(el().wFull().h(1).bg(t.separator))
        .child(results)
}
```

Configure the window on `App<LauncherState>` with `.floatOnOpen()`, `.fitContentHeight()`, and a global shortcut. See `Sources/Examples/RuneLauncher` (`swift run rune-launcher`).

---

## 6. Unified macOS Titlebar & Toolbar (`chromeInsets` + `windowDrag`)

macOS apps like Finder, Safari, Xcode, and Notes draw their own toolbar right inside the titlebar band while keeping native traffic lights (and Windows min/max/close caption buttons!) fully functional:

```swift
func unifiedTitlebarView(_ s: AppState, _ cx: inout Cx<AppState>) -> El<AppState> {
    let dark = cx.systemDark
    let t = Tok.theme(dark: dark)
    let barHeight: Float = 44

    // Keep native window controls legible and aligned to your toolbar height
    cx.captionColor(dark ? .white : .black)
    cx.titlebarHeight(barHeight)
    let insets = cx.chromeInsets() // traffic lights on macOS, caption buttons on Windows

    let titlebar = row()
        .key("titlebar")
        .wFull()
        .h(barHeight)
        .bg(t.card)
        .centerY()
        .windowDrag()                     // drag empty space to move window; buttons still click!
        .pl(insets.leading + 12)
        .pr(insets.trailing + 12)
        .gap(8)
        .child(text("Workspace").font(Tok.Typography.title).color(t.text))
        .child(spacer())
        .child(toolbarActions)

    return col()
        .sizeFull()
        .bg(t.bg)
        .child(titlebar)
        .child(mainContent.grow(1).minH(0))
}
```

Attach `.titlebar(...)` to `App<AppState>` and use `.modal(clickOutside: true) { ... }` for sheets that dismiss on outside click while keeping window chrome interactive. See `Sources/Examples/RuneCustomTitlebar` (`swift run rune-custom-titlebar`).

---

## 7. Notes / Mail / Finder Split-View App

Combine `RuneKit`'s `sidebar`, `paneGroup`, and `statusBar` with Apple-style sidebar selection pills:

```swift
import Rune
import RuneKit

func notesAppView(_ s: NotesState, _ cx: inout Cx<NotesState>) -> El<NotesState> {
    let kit = Kit.neutral(dark: cx.systemDark)

    var sidebarList = col().key("notes-list").p(8).gap(2)
    for note in s.notes {
        let selected = note.id == s.selectedID
        sidebarList = sidebarList.child(
            row()
                .key("note-\(note.id)")
                .role(.listItem)
                .itemSelected(selected)
                .h(32).px(10).rounded(6).itemsCenter()
                .bg(selected ? kit.c.bgAccent : .transparent)
                .hover(selected ? .transparent : kit.c.hover)
                .onClick { $0.selectedID = note.id }
                .child(
                    text(note.title)
                        .font(selected ? kit.ty.uiMedium : kit.ty.ui)
                        .color(selected ? kit.c.textContrast : kit.c.textBase)
                        .ellipsis()
                )
        )
    }

    return col()
        .sizeFull()
        .bg(kit.c.page)
        .child(
            row().wFull().grow(1).minH(0)
                .child(
                    kit.sidebar(
                        key: "sidebar",
                        pane: s.sidebar,
                        title: "Notes",
                        content: sidebarList.scroll(stickBottom: false),
                        onToggle: { $0.sidebar.isOpen.toggle() }
                    )
                )
                .child(
                    col().grow(1).minW(0).hFull().p(24).gap(12)
                        .child(text(s.currentNote.title).font(kit.ty.bodyMedium).color(kit.c.textBase))
                        .child(kit.textArea(key: "editor", \.currentBody, minHeight: 300).grow(1))
                )
        )
        .child(
            kit.statusBar(
                leading: text("\(s.notes.count) notes").font(kit.ty.small).color(kit.c.textMuted),
                trailing: text("Synced").font(kit.ty.small).color(kit.c.textMuted)
            )
        )
}
```

---

## 8. Apple Platform Polish Checklist

1. **120 Hz ProMotion on iPhone & iPad**: Embed via `IOSApp.makeViewController(app)` and set `CADisableMinimumFrameDurationOnPhone = YES` in `Info.plist`.
2. **macOS Window Frame Persistence**: Add `.product(name: "RuneMac", package: "swift-rune")` for automatic `NSWindow` frame autosave and multi-display clamping.
3. **Native Notifications**: Add `.product(name: "RuneNotify", package: "swift-rune")` for `UserNotifications` on Apple platforms (plus WinRT toasts on Windows and freedesktop notifications on Linux).
4. **Cross-Platform Shortcut Ergonomics**: Use `"mod+..."` in `Chord.parse(...)` and `RuneKit` shortcuts—automatically displaying `⌘` on macOS and `Ctrl+` on Windows/Linux.
5. **Respect Reduced Motion & System Appearance**: Always derive colors from `cx.systemDark` (unless user-overridden) and honor `cx.reducedMotion`.

### Apple-Style Examples to Run

```bash
xcrun swift run rune-settings          # macOS System Settings panel
xcrun swift run rune-frosted-bar       # iOS frosted bottom tab bar
xcrun swift run rune-glass-card        # Liquid Glass morphing card
xcrun swift run rune-glass-panel       # Cross-platform refractive glass panel
xcrun swift run rune-launcher          # Spotlight-style command launcher + Notes window
xcrun swift run rune-custom-titlebar   # Unified custom titlebar & toolbar
xcrun swift run rune-matched           # Matched-geometry spring transitions
xcrun swift run rune-motion-bento      # Apple-style bento motion showcase
```
