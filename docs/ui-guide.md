# Rune UI Programming Guide

`Rune` is an immediate-style declarative UI library backed by a retained layout, animation, accessibility, and GPU rendering runtime. You store application state in a plain Swift value (`State`), describe your interface as a pure function returning `El<State>`, and mutate state inside event callbacks.

## Core Mental Model

Every Rune app consists of three parts:

1. **State** — A Swift struct holding your UI and domain state.
2. **View function** — `(State, inout Cx<State>) -> El<State>` that builds the declarative element tree.
3. **App specification** — `AppSpec<State>` (simple) or `App<State>` (full window/lifecycle control) passed to `RuneApp.run(...)`.

```swift
import Rune

struct CounterState {
    var count: Int = 0
}

func counterView(_ s: CounterState, _ cx: inout Cx<CounterState>) -> El<CounterState> {
    let t = Tok.theme(dark: cx.systemDark)
    return col()
        .sizeFull()
        .center()
        .gap(12)
        .bg(t.bg)
        .child(text("Count: \(s.count)").font(Tok.Typography.title).color(t.text))
        .child(
            row()
                .key("inc-btn")
                .role(.button)
                .label("Increment")
                .focusable(true)
                .px(16).py(8)
                .rounded(Tok.Radius.md)
                .bg(Tok.accent(0, dark: cx.systemDark))
                .hover(t.hover)
                .press(t.press)
                .onClick { $0.count += 1 }
                .child(text("+1").color(.white).semibold())
        )
}
```

### `AppSpec<State>` vs `App<State>`

- **`AppSpec<State>`** is the concise entry point for most apps: title, initial size, minimum size, initial state, view function, named `.scene(...)` presets, custom fonts, `setup(Waker)`, `poll`, `onKey`, and `onFileDrop`.
- **`App<State>`** unlocks advanced desktop/browser capabilities:
  - Custom window chrome (`Chrome`, `Titlebar`) and macOS window options
  - Native menus (`NativeMenuItem`) and global shortcuts
  - Multi-window factories and floating overlays (`OverlaySpec` / `OverlayHandle`)
  - Lifecycle hooks (`onFocus`, `onClose`, `onQuit`, `onReopen`, `onOpenUrl`, `onWindow`, `onReady`)
  - Custom native GPU passes via `Compositor`
  - Web document scrolling (`.webDocument()`, `.canvasId(...)`, `.fullViewport()`)

### Context (`Cx`) & Transactions (`Tx`)

- **`Cx<State>`** is passed to your view function each frame. Use it to read `cx.systemDark`, `cx.pixelScale`, viewport size, focus state, or configure frame-wide settings like `cx.reducedMotion(_:)` and `cx.timeScale(_:)`.
- **`Tx`** is passed to rich callbacks (`onClick { state, tx in ... }`, `poll`, `onKey`). Use `tx` to request focus changes, schedule wakes (`tx.wakeAfter(seconds)`), copy to the clipboard, or trigger platform commands.
- **Background work & async tasks**: Register a `.setup { waker in ... }` hook on `AppSpec` or `App` and call `waker.wake()` from any thread whenever external data changes to schedule a redraw.

---

## Building Element Trees

### Element Constructors

| Builder | Purpose |
| :--- | :--- |
| `el()` | Generic box container or surface |
| `col()` | Vertical flex container (`flex-direction: column`) |
| `row()` | Horizontal flex container (`flex-direction: row`) |
| `text("...")` | Styled text run (supports wrapping, truncation, alignment) |
| `rich(...)` | Multi-span rich text with mixed styles and inline pills |
| `icon(svg, size:)` | Crisp GPU-rendered vector `SVGIcon` |
| `image(...)` | Raster/animated image loaded via `ImageCache` |
| `canvas(...)` | Custom vector / 2D drawing region |
| `textInput(key: \State.edit)` | Full Unicode grapheme text editor with IME, selection, and spellcheck |
| `spacer()` | Flexible space-filling element |
| `rule(thickness, color)` | Hairline divider |

### Keys & Identity

Assign a stable `.key("...")` to interactive, animated, focusable, or dynamically reordered elements (for example `.key("todo-\(item.id)")`). Keys let Rune preserve:

- Focus and text selection across rebuilds
- Smooth velocity-preserving spring animations
- Enter/exit transitions and layout morphing
- Scroll positions and accessibility node identity

---

## Layout & Styling

Rune includes `RuneTaffy`, a full Flexbox, CSS Grid, Block, and Absolute positioning engine.

### Sizing & Spacing

```swift
col()
    .sizeFull()          // wFull().hFull()
    .w(320).minH(120)    // explicit width / minimum height
    .wFrac(0.5)          // 50% width
    .p(16)               // padding on all sides
    .px(12).py(8)        // horizontal / vertical padding
    .pt(4).pb(12).pl(8).pr(8)
    .m(8)                // margins (mx, my, mt, mb, ml, mr)
    .gap(12)             // gap between children
```

### Alignment & Flex Behavior

```swift
row()
    .center()            // center both axes
    .centerY()           // align-items: center
    .itemsStart()        // align-items: flex-start
    .justifyBetween()    // justify-content: space-between
    .child(text("Title").grow(1).minW(0))
    .child(text("Meta").shrink(0))
```

### Absolute Positioning & Layering

```swift
el()
    .absolute(x: 16, y: 8)   // explicit offset from parent
    .pin(top: 0, right: 0, bottom: 0, left: 0) // fill parent overlay
    .z(50)                   // painter z-order
```

### Visual Styling

```swift
el()
    .bg(Color.oklch(0.24, 0.01, 265))
    .rounded(Tok.Radius.lg)          // or .pill()
    .border(1, Color.white.alpha(0.1))
    .shadow(Shadow(x: 0, y: 4, blur: 16, color: Color.black.alpha(0.3)))
    .opacity(0.95)
    .clip(true)
```

### Colors & Design Tokens (`Color` & `Tok`)

Rune works in linear-light RGBA internally and provides ergonomic color constructors:

- `Color.hex("#3b82f6")!` — sRGB hex (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`)
- `Color.oklch(0.66, 0.17, 256)` / `Color.oklcha(...)` — perceptual OKLCH
- `Color.srgb(r, g, b, a)` and `Color.rgba8(r, g, b, a)`
- `color.alpha(0.5)`, `color.mixOklab(with: other, t: 0.5)`, `color.contrastRatio(with: bg)`
- `Tok.theme(dark: Bool)` — curated light/dark neutral tokens (`bg`, `card`, `cardBorder`, `separator`, `text`, `textSecondary`, `controlOff`, `knob`, `hover`, `press`, `shadow`)
- `Tok.accent(0..<6, dark: Bool)` — six perceptual accents (blue, purple, pink, orange, green, graphite)
- `Tok.Space`, `Tok.Radius`, `Tok.Typography`, `Tok.Motion`
- `JsonTheme.fromJSON(_:dark:)` — load external JSON themes

### Scrolling & Large Lists

Make any container scrollable with `.scroll(...)`:

```swift
list
    .scroll(stickBottom: true)
    .shrink(1)
    .minH(0)
```

For tens of thousands of items (such as 100,000-row tables or 50,000-file trees), use Rune's virtualized stack/list support or `RuneKit`'s virtualized `table` and `tree` components.

---

## Interactivity, Input & Accessibility

### Pointer & Hover States

```swift
el()
    .key("action")
    .focusable(true)
    .hover(t.hover)
    .press(t.press)
    .onClick { state in
        state.selected = true
    }
    .onClick { state, tx in
        // Access Tx when needed
    }
    .onDrag { state, drag in
        // drag.phase (.down / .move / .up), drag.local, drag.delta, drag.isCancelled
    }
```

### Text Editing (`TextEdit`)

Store a `TextEdit` value in your state and bind it via a writable key path:

```swift
struct EditorState {
    var draft = TextEdit("Initial text")
}

// Inside view:
textInput(key: "draft", \EditorState.draft)
    .singleLine()
    .placeholder("Type something...", color: t.textSecondary)
    .onSubmit { state, value, _ in
        print("Submitted:", value)
    }
```

`TextEdit` supports Unicode grapheme clusters, word/line navigation, clipboard copy/paste, IME composition, undo/redo, and optional `.spellcheck()`.

### Accessibility

Rune bridges your element tree directly to native OS accessibility services (NSAccessibility on macOS, UIAccessibility on iOS, UI Automation on Windows, AT-SPI on Linux, AccessibilityNodeProvider on Android, and DOM/ARIA on Web):

```swift
el()
    .key("lights-switch")
    .role(.switchControl)
    .label("Lights")
    .selected(state.on ? "true" : "false")
    .focusable(true)
```

---

## Motion & Animation (`RuneMotion`)

`Rune` re-exports `RuneMotion`, providing analytic, velocity-preserving springs and layout morphing:

### Property & Color Animation

```swift
el()
    .key("switch")
    .bg(state.on ? accent : t.controlOff)
    .animate(Tok.Motion.SNAPPY) // animates bg, opacity, transforms in OKLab/linear space
```

### 4-Edge Layout Morphing

```swift
el()
    .key("knob")
    .absolute(x: state.on ? 20 : 2, y: 2)
    .animateLayout(Spring(duration: 0.35, bounce: 0.2))
```

### Enter & Exit Transitions

```swift
if state.showBanner {
    el()
        .key("banner")
        .transition(Transition.scale(0.95).spring(Tok.Motion.POP))
}
```

### Built-in Motion Presets

- `Tok.Motion.INSTANT`
- `Tok.Motion.SNAPPY`
- `Tok.Motion.DEFAULT`
- `Tok.Motion.CALM`
- `Tok.Motion.MORPH`
- `Tok.Motion.POP`
- `Tok.Motion.LEAD`
- Custom springs: `Spring(duration: 0.4, bounce: 0.2)`

---

## Custom GPU Rendering (`Compositor`)

To embed custom Metal (Apple), OpenGL (Windows/Linux/Android), or WebGPU/WebGL 2 (Browser) passes inside your UI:

1. Mark a slot in your view tree with `.effect(mark)` (add `.effectBackdrop(true)` if your shader samples content painted behind it).
2. Attach a `Compositor` to `App` via `app.compositor(...)`.
3. Inside `render(frame:)`, call `try frame.drawUI(withEffects:)` to run your native GPU callback at each visible slot in painter order.

See `Sources/Examples/RuneLightLive`, `Sources/Examples/RuneFxGallery`, and `Sources/Examples/RuneGlassPanel` for complete examples.

---

## Headless Rendering & Visual Testing

Every `RuneApp` supports headless execution out of the box—ideal for unit tests, golden-image diffs, and CI pipelines without a display server:

```bash
# Render a PNG snapshot
swift run MyApp --snap frame.png --scene on --dark --size 800x600 --scale 2

# Render at a specific animation timestamp (seconds)
swift run MyApp --snap mid-spring.png --scene on --at 0.12

# Inspect the full laid-out tree and accessibility metadata
swift run MyApp --tree layout.json

# Drive scripted pointer/keyboard input and record frames
swift run MyApp --script interaction.json --frames ./out-frames --fps 60
```

You can also use `HeadlessRunner` and `RuneRef.diff` directly inside Swift unit tests to assert pixel and layout parity programmatically.
